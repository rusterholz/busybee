# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require "busybee/client/call"
require "busybee/error"
require "busybee/hooks"
require "busybee/worker/configuration"
require "busybee/worker/dsl"
require "busybee/worker/shutdown"
require "busybee/worker/status"
require "busybee/worker/timestamps"

module Busybee
  # Base class for defining job workers.
  #
  # Subclass and implement `perform` to handle jobs from the workflow engine.
  # Runners call `perform_job(job)` as the entry point (internal use only).
  #
  # @example Minimal worker
  #   class ProcessOrderWorker < Busybee::Worker
  #     job_type "process-order"
  #
  #     def perform
  #       order = Order.find(variables[:order_id])
  #       order.process!
  #       complete!(status: order.status)
  #     end
  #   end
  #
  class Worker
    extend DSL

    attr_reader :job

    delegate :variables, :headers, :client, :fail!, :throw_bpmn_error!,
             :update_retries, :update_timeout, to: :job

    # Container identity (Busybee.worker_name) — not the per-job worker instance.
    # Explicit identity for metrics/registries.
    delegate :worker_name, to: :Busybee

    def complete!(vars = {})
      self.class.validate_required_outputs!(vars)
      self.class.validate_undeclared_outputs!(vars)
      job.complete!(vars)
    end

    def initialize(job)
      @job = job
    end

    def perform
      raise NotImplementedError,
            "#{self.class.name} must implement `perform`"
    end

    class << self
      # Entry point called by Runners. Instantiates the worker, validates inputs,
      # calls perform, and applies lifecycle behaviors (auto-complete, auto-fail, shutdown).
      #
      # Contract with Runners:
      # - Returns normally: job was handled, runner continues.
      # - Raises Shutdown: worker is unhealthy, runner should shut down.
      #
      # @param job [Busybee::Job] An activated job from the workflow engine
      # @return [Hash, nil] the result returned by perform (as a HashWithIndifferentAccess)
      #   on success, or nil on the rescue path
      # @raise [Busybee::Worker::Shutdown] if a shutdown_on exception is caught
      def perform_job(job)
        Client::Call.with_job(job) do # job window spans the whole chain: hooks, perform, autofail all fold it
          run_perform_envelope(job)
        rescue StandardError => e
          # handle_perform_exception only ever re-raises a Shutdown, so anything
          # else reaching here was raised by after_perform.
          raise if e.is_a?(Shutdown)

          handle_perform_exception(job, e)
        end
      end

      # Validate that `result` includes every output declared `required: true`.
      # Used by both auto-complete (perform_job's success path) and the
      # instance #complete! method.
      #
      # @raise [Busybee::MissingOutput] if any required output is missing
      def validate_required_outputs!(result, config = configuration)
        missing = config.outputs.select(&:required).reject { |o| result.key?(o.name) || result.key?(o.name.to_s) }
        return if missing.empty?

        names = missing.map { |o| ":#{o.name}" }.join(", ")
        raise Busybee::MissingOutput, "Missing required outputs for #{config.job_type} worker: #{names}"
      end

      # Validate that `result` includes no keys beyond the declared outputs,
      # when `strict_outputs` is enabled. Used by both auto-complete and the
      # instance #complete! method.
      #
      # @raise [Busybee::UndeclaredOutput] if any undeclared output is present
      def validate_undeclared_outputs!(result, config = configuration)
        return unless config.strict_outputs?

        declared = config.outputs.flat_map { |o| [o.name, o.name.to_s] }
        undeclared = result.keys.reject { |k| declared.include?(k) }
        return if undeclared.empty?

        names = undeclared.map { |k| ":#{k}" }.join(", ")
        raise Busybee::UndeclaredOutput,
              "Undeclared outputs for #{config.job_type} worker: #{names}. " \
              "Declare with `output :name` or set `strict_outputs false`"
      end

      private

      # after_perform propagates like the rest of the triple. An ensure on
      # perform-plus-auto-resolution: it fires here rather than around perform
      # proper so the outcome is already on the carrier when it does.
      def run_perform_envelope(job)
        job.timestamps.stamp!(:execution_started_at)
        instance = new(job)
        job.set_context(worker: instance)

        run_hooked_perform(instance)
      rescue StandardError => e
        handle_perform_exception(job, e)
      ensure
        Hooks.run(:after_perform, job) if job.timestamps.perform_started_at
      end

      def handle_perform_exception(job, exception)
        # Capture early so after_perform hooks see the error attached to Job even
        # when autofail's GRPC fails. fail!'s own set_error during autofail
        # no-ops harmlessly.
        job.send(:resolution).set_error(Shutdown.unwrap(exception))
        handle_failure(job, exception, configuration)
        raise if exception.is_a?(Shutdown)
        raise Shutdown.new(worker_class: self) if Shutdown.triggered_by?(exception, self)
      end

      # Per-line-item gating: every step asks whether work is still on the table
      # at the moment it arrives, not once on the way in. A hook that resolves
      # the job therefore stops everything downstream of it — including the
      # middleware that would otherwise wrap work no longer going to happen.
      # The perform-like moments fire exactly when perform is attempted; an
      # invalid job and a short-circuited one both skip the lot, and the system
      # lifecycle hooks carry the observation instead.
      def run_hooked_perform(instance)
        job = instance.job
        validate_inputs!(instance, configuration) if job.ready?
        Hooks.run(:before_perform, job) if job.ready?
        result =
          if job.ready?
            Hooks.run_chain(:around_perform, job) { timed_perform(instance) if job.ready? }
          end
        log_short_circuit(job)
        handle_success(job, result, configuration)
        result
      end

      # A hook resolved the job before perform could run. Reported here rather
      # than at whichever gate first noticed: the gates are temporal, and
      # skipping the around_perform chain means perform's own gate is never
      # evaluated, so no single gate sees every short-circuit. Sits on the
      # non-raising path, which is what separates a deliberate short-circuit
      # from an invalid job — that one leaves by way of MissingInput.
      def log_short_circuit(job)
        return unless job.resolved? && job.timestamps.perform_started_at.nil?

        Busybee.logger&.info(
          "[busybee] Job #{job.key} was resolved by a hook before perform ran; perform skipped"
        )
      end

      def timed_perform(instance)
        instance.job.timestamps.stamp!(:perform_started_at)
        begin
          instance.perform
        ensure
          instance.job.timestamps.stamp!(:perform_finished_at)
        end
      end

      def validate_inputs!(instance, config)
        missing = config.inputs.select(&:required).reject { |input| input_present?(instance, input) }
        return if missing.empty?

        names = missing.map { |i| ":#{i.name}" }.join(", ")
        raise Busybee::MissingInput, "Missing required inputs for #{configuration.job_type} worker: #{names}"
      end

      def input_present?(instance, input)
        Array(input.source).any? { |src| !instance.public_send(:"#{src}s")[input.name.to_s].nil? }
      end

      def handle_success(job, result, config)
        return unless config.complete_job_on_success && job.ready?

        new_vars = result.is_a?(Hash) ? result : {}
        validate_required_outputs!(new_vars, config)
        validate_undeclared_outputs!(new_vars, config)
        begin
          job.complete!(new_vars)
        rescue StandardError => e
          # Capture the failure on Resolution's error axis so after_perform and
          # on_job_executed hooks see why complete! failed, even though the
          # error is logged-and-swallowed here. Symmetry with G2's early
          # capture in handle_perform_exception.
          job.send(:resolution).set_error(e)
          Busybee.logger&.warn("Failed to complete job #{job.key}: #{e.message}. Job will timeout and retry.")
        end
      end

      def handle_failure(job, error, config)
        unless job.ready?
          log_post_resolution_error(job, error)
          return
        end

        attempt_auto_fail(job, error, config)
      end

      def log_post_resolution_error(job, error)
        location = error.backtrace&.first
        suffix = location ? " (at #{location})" : ""
        Busybee.logger&.warn(
          "Error in #{configuration.job_type} worker for job #{job.key} " \
          "after job was already #{job.status}: [#{error.class}] #{error.message}#{suffix}"
        )
      end

      def attempt_auto_fail(job, error, config)
        job.fail!(Shutdown.unwrap(error), backoff: config.fail_job_backoff)
      rescue StandardError => e
        Busybee.logger&.warn("Failed to fail job #{job.key}: #{e.message}. Job will timeout and retry.")
      end
    end
  end
end
