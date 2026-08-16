# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "concurrent"

require "busybee/client/call"
require "busybee/durations"
require "busybee/error"
require "busybee/job/activation"
require "busybee/job/context"
require "busybee/job/error_formatting"
require "busybee/job/payload"
require "busybee/job/resolution"
require "busybee/job/timestamps"
require "busybee/serialization"

module Busybee
  # Represents a job activated from Zeebe for processing by a worker.
  #
  # Wraps the raw GRPC ActivatedJob protobuf with a Ruby-idiomatic interface.
  # Tracks job status to prevent double-completion bugs.
  #
  # @example Complete a job
  #   job = Busybee::Job.new(raw_job, client: client)
  #   job.complete!(result: "success")
  #
  # @example Fail a job with retry
  #   job.fail!("Payment gateway timeout", retries: 3, backoff: 30.seconds)
  #
  # @example Throw a BPMN error
  #   job.throw_bpmn_error!(:order_not_found, "Order #{order_id} not found")
  #
  class Job
    include ErrorFormatting

    attr_reader :client, :payload, :timestamps, :context

    delegate :key, :type, :job_type, :process_instance_key, :bpmn_process_id, :element_id,
             :variables, :headers,
             to: :payload
    delegate :source, :buffered?, :worker, :worker_class, :worker_status, to: :activation
    delegate :status, :result, :error, :error_message, :error_code,
             :ready?, :complete?, :completed?, :failed?, :error?, :errored?, :resolved?,
             to: :resolution
    delegate :perform_duration_ms, :resolution_duration_ms, :execution_duration_ms,
             :buffer_latency_ms, :total_duration_ms, :post_resolution_ms, :setup_duration_ms,
             to: :timestamps

    # Per-moment timestamp readers (job.activated_at, job.executed_at, etc.)
    # forward to the Timestamps PORO, kind arg and all — delegate forwards it,
    # and the :utc default lives on the PORO. job.timestamps.stamp! remains the
    # write surface; there is no Job-level stamp! delegate.
    delegate(*Timestamps.timestamp_names, to: :timestamps)

    # Container identity (Busybee.worker_name) — the per-job worker instance is
    # job.worker; this is the process/container the job ran in.
    delegate :worker_name, to: :Busybee

    # Non-predicate reader for the `buffered` hook filter key: Hooks.attribute
    # resolves a filter value via public_send(key), and a kwarg key can't carry
    # the `?`. buffered? (delegated above) stays the idiomatic predicate.
    def buffered = buffered? # rubocop:disable Naming/PredicateMethod

    # Create a new Job wrapper.
    #
    # @param raw_job [Busybee::GRPC::ActivatedJob] The raw GRPC job protobuf
    # @param client [Busybee::Client] The client instance for completing/failing jobs
    def initialize(raw_job, client:)
      @payload = Payload.new(raw_job)
      @client = client
      @activation = Activation.new
      @resolution = Resolution.new
      @context = Context.new
      @timestamps = Timestamps.new
      # Per-job AND per-thread: the guard is about what the thread holding the
      # job is currently doing, so it follows the runner's thread through the
      # hook fires and never reaches a thread perform handed work to.
      @status_changes_prevented = Concurrent::ThreadLocalVar.new(false)
    end

    # Route a kwargs hash through the Job's typed POROs. Activation-owned
    # keys (source, buffer_size, worker, worker_class) land in Activation;
    # Resolution-owned keys (Resolution::OWNED_KEYS) are intentionally NOT
    # routed here — they have dedicated lifecycle methods (#complete!,
    # #fail!, #throw_bpmn_error!) and a warning fires if they show up.
    # Everything else is absorbed by Context as arbitrary scratch.
    def set_context(**kwargs)
      warn_about_reserved_keys(kwargs)
      kwargs = kwargs.except(*Resolution::OWNED_KEYS)
      activation.harvest!(kwargs)
      context.absorb(kwargs)
      self
    end

    # Low-cardinality projection of the job's state (suitable for metric
    # labels). Job prepends the override-aware retries it owns, then merges
    # each PORO's contribution. Later entries override earlier on key collision
    # (retries < payload < activation < resolution < timestamps < context).
    def context_tags
      { retries: retries }.compact.
        merge(payload.context_tags).
        merge(activation.context_tags).
        merge(resolution.context_tags).
        merge(@timestamps.context_tags).
        merge(@context.context_tags)
    end

    # High-cardinality projection of the job's state. Strict superset of
    # context_tags: each component's logging_context contains everything its
    # context_tags does plus additional unbounded-dimension values. Job prepends
    # the override-aware retries and deadline it owns.
    def logging_context
      { retries: retries, deadline: deadline }.compact.
        merge(payload.logging_context).
        merge(activation.logging_context).
        merge(resolution.logging_context).
        merge(@timestamps.logging_context).
        merge(@context.logging_context)
    end

    # Run a region in which the job cannot be resolved — every hook fire.
    # #bind saves and restores rather than setting and clearing, because the
    # regions nest: the runner's bracket around around_job_execution contains
    # the worker's bracket around the perform triple, which contains perform.
    # @api private
    def _with_status_changes_prevented(&) = @status_changes_prevented.bind(true, &)

    # Run a region in which the job may be resolved — perform, and the
    # automatic resolution the worker performs on its behalf.
    # @api private
    def _with_status_changes_allowed(&) = @status_changes_prevented.bind(false, &)

    # Number of retries remaining. Layers an override from update_retries on
    # top of the protobuf value.
    # @return [Integer]
    def retries
      @retries_override || payload.retries
    end

    # Job deadline as a frozen Time. Layers an override from update_timeout on
    # top of the protobuf value.
    # @return [Time]
    def deadline
      @deadline_override || payload.deadline
    end

    # Complete the job with optional output variables.
    #
    # @param vars [Hash] Variables to return to the workflow engine
    # @return [Object] Response from complete_job operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def complete!(vars = {})
      ensure_resolvable!(:complete, "complete")

      resolution.set_result(vars)
      correlated { @client.complete_job(key, vars: resolution.result || {}) }.tap do
        resolve!(:complete)
      end
    end

    # Fail the job with an error message.
    #
    # @param message_or_exception [String, Exception] Error message or exception
    # @param retries [Integer, nil] Override retry count
    # @param backoff [Integer, ActiveSupport::Duration, nil] Backoff before retry
    # @return [Object] Response from fail_job operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def fail!(message_or_exception, retries: nil, backoff: nil)
      ensure_resolvable!(:fail, "fail")

      message = format_error_message(message_or_exception)
      error_data = if message_or_exception.is_a?(Exception)
                     { error: message_or_exception }
                   else
                     { error_message: message }
                   end
      resolution.set_error(error_data)

      new_retries = next_retries(retries)
      correlated { @client.fail_job(key, message, retries: new_retries, backoff: backoff) }.tap do
        @retries_override = new_retries
        resolve!(:failed)
      end
    end

    # Throw a BPMN error to be caught by an error boundary event.
    #
    # @param code_or_exception [String, Symbol, Exception] Error code or exception
    # @param message [String] Optional error message
    # @return [Object] Response from throw_bpmn_error operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def throw_bpmn_error!(code_or_exception, message = "")
      ensure_resolvable!(:throw_bpmn_error, "throw BPMN error on")

      code = format_error_code(code_or_exception)
      message = code_or_exception.message if code_or_exception.is_a?(Exception) && message.empty?
      resolution.set_error(bpmn_error_data(code_or_exception, code, message))

      correlated { @client.throw_bpmn_error(key, code, message: message) }.tap do
        resolve!(:error)
      end
    end

    # Update the retry count for this job.
    #
    # @param count [Integer] The new number of retries
    # @return [Object] Response from update_job_retries operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_retries(count)
      correlated { @client.update_job_retries(key, count) }.tap do
        @retries_override = count
      end
    end

    # Update the timeout for this job.
    #
    # @param duration [Integer, ActiveSupport::Duration] New timeout in milliseconds
    # @return [Object] Response from update_job_timeout operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_timeout(duration)
      duration_seconds = Busybee::Durations.seconds_from(duration)
      correlated { @client.update_job_timeout(key, duration) }.tap do
        @deadline_override = (Time.now.utc + duration_seconds).freeze
      end
    end

    private

    attr_reader :activation, :resolution

    # A job's own engine calls carry the job whatever the thread — a manual
    # complete!/fail! from outside the perform window (an async worker's own
    # thread) would otherwise build an uncorrelated Call.
    def correlated(&) = Client::Call.with_job(self, &)

    # Shared fire-once guard for the resolution ops.
    def ensure_resolvable!(action, verb)
      check_status_change_allowed!(action)
      return if ready?

      raise Busybee::JobAlreadyHandled, "Cannot #{verb} job #{key} because it is already #{status}"
    end

    # Failing spends one retry — Zeebe doesn't auto-decrement on FailJob, the
    # worker owns it. A bare fail! decrements the current count; an explicit
    # retries: (incl. 0) sets it outright. Either way #retries mirrors it after.
    def next_retries(explicit)
      explicit || ((@retries_override || payload.retries) - 1)
    end

    # Mark the job resolved: stamp resolved_at, advance the Resolution PORO
    # to the terminal status (fire-once enforced). Outcome data (result /
    # error trio) is captured separately by the calling lifecycle method
    # (#complete!, #fail!, #throw_bpmn_error!) before its GRPC. after_perform
    # firing happens uniformly post-perform in Worker.perform_job's ensure,
    # not here.
    def resolve!(status)
      @timestamps.stamp!(:resolved_at)
      resolution.resolve_to(status)
    end

    def warn_about_reserved_keys(kwargs)
      reserved = kwargs.keys & Resolution::OWNED_KEYS
      reserved.each do |key|
        Busybee.logger&.warn(
          "[busybee] :#{key} passed to Job#set_context will be dropped — " \
          "use Job#complete!, #fail!, or #throw_bpmn_error! to capture outcome data."
        )
      end
    end

    def check_status_change_allowed!(operation)
      return unless @status_changes_prevented.value

      raise Busybee::StatusChangeOutsidePerform,
            "Cannot #{operation} job #{key} outside perform — " \
            "status changes are not allowed during hook execution"
    end
  end
end
