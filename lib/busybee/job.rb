# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "busybee/serialization"
require "busybee/job/activation"
require "busybee/job/context"
require "busybee/job/error_formatting"
require "busybee/job/payload"
require "busybee/job/resolution"
require "busybee/job/timestamps"

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
    delegate :source, :buffer_size, :worker, :worker_class, to: :activation
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
    delegate(*Timestamps::NAMES, to: :timestamps)

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
      @status_changes_prevented = false
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

    # Prevent status changes during hook execution.
    # @api private
    def _prevent_status_changes!
      @status_changes_prevented = true
    end

    # Re-enable status changes (before perform, on rescue entry).
    # @api private
    def _allow_status_changes!
      @status_changes_prevented = false
    end

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
      check_status_change_allowed!(:complete)
      raise Busybee::JobAlreadyHandled, "Cannot complete job #{key} because it is already #{status}" unless ready?

      resolution.set_result(vars)
      @client.complete_job(key, vars: resolution.result || {}).tap do
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
      check_status_change_allowed!(:fail)
      raise Busybee::JobAlreadyHandled, "Cannot fail job #{key} because it is already #{status}" unless ready?

      message = format_error_message(message_or_exception)
      error_data = if message_or_exception.is_a?(Exception)
                     { error: message_or_exception }
                   else
                     { error_message: message }
                   end
      resolution.set_error(error_data)

      @client.fail_job(key, message, retries: retries, backoff: backoff).tap do
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
      check_status_change_allowed!(:throw_bpmn_error)
      unless ready?
        raise Busybee::JobAlreadyHandled,
              "Cannot throw BPMN error on job #{key} because it is already #{status}"
      end

      code = format_error_code(code_or_exception)
      message = code_or_exception.message if code_or_exception.is_a?(Exception) && message.empty?
      resolution.set_error(bpmn_error_data(code_or_exception, code, message))

      @client.throw_bpmn_error(key, code, message: message).tap do
        resolve!(:error)
      end
    end

    # Update the retry count for this job.
    #
    # @param count [Integer] The new number of retries
    # @return [Object] Response from update_job_retries operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_retries(count)
      @client.update_job_retries(key, count).tap do
        @retries_override = count
      end
    end

    # Update the timeout for this job.
    #
    # @param duration [Integer, ActiveSupport::Duration] New timeout in milliseconds
    # @return [Object] Response from update_job_timeout operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_timeout(duration)
      duration_seconds = duration.is_a?(ActiveSupport::Duration) ? duration.in_seconds : duration / 1000.0
      @client.update_job_timeout(key, duration).tap do
        @deadline_override = (Time.now.utc + duration_seconds).freeze
      end
    end

    private

    attr_reader :activation, :resolution

    # Mark the job resolved: stamp resolved_at, advance the Resolution PORO
    # to the terminal status (fire-once enforced). Outcome data (result /
    # error trio) is captured separately by the calling lifecycle method
    # (#complete!, #fail!, #throw_bpmn_error!) before its GRPC. after_job
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
      return unless @status_changes_prevented

      raise Busybee::StatusChangeOutsidePerform,
            "Cannot #{operation} job #{key} outside perform — " \
            "status changes are not allowed during hook execution"
    end
  end
end
