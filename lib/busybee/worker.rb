# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "busybee/worker/configuration"
require "busybee/worker/dsl"
require "busybee/worker/shutdown"
require "busybee/worker/timestamps"
require "busybee/worker/status"

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
      # @raise [Busybee::StatusChangeOutsidePerform] if a hook calls complete!/fail!/throw_bpmn_error!
      def perform_job(job)
        Client::Call.with_job(job) do # job window spans the whole chain: hooks, perform, autofail all fold it
          job.timestamps.stamp!(:execution_started_at)
          instance = new(job)
          job.set_context(worker: instance)

          run_hooked_perform(instance)
        rescue StandardError => e
          handle_perform_exception(job, e)
        ensure
          # Defensive: ensure the status-change flag is cleared on every exit
          # path, including non-StandardError exceptions that escape the rescue.
          job._allow_status_changes!
          # Conditional on resolved?: after_job marks the moment the lifecycle
          # reached a settled outcome the engine has on file. When the engine
          # didn't learn (autofail disabled, any GRPC fail mid-resolution), the
          # job will be re-yielded; per-attempt observability belongs to
          # on_job_executed (runner-level, unconditional).
          Hooks.run(:after_job, job, safe: true) if job.resolved?
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

      def handle_perform_exception(job, exception)
        job._allow_status_changes!
        # Capture early so after_job hooks see the error attached to Job even
        # when autofail is disabled (fail_job_on_error: false) or autofail's
        # GRPC fails. fail!'s own set_error during autofail no-ops harmlessly.
        job.send(:resolution).set_error(underlying_error(exception))
        handle_failure(job, exception, configuration)
        raise if exception.is_a?(Shutdown) || exception.is_a?(Busybee::StatusChangeOutsidePerform)
        raise Shutdown.new(worker: self) if shutdown_error?(exception, configuration)

        log_unhandled_error(job, exception) unless configuration.fail_job_on_error
      end

      def run_hooked_perform(instance)
        job = instance.job
        validate_inputs!(instance, configuration)
        job._prevent_status_changes!
        Hooks.run(:before_job, job)
        result = Hooks.run_chain(:around_job, job) do
          job._allow_status_changes!
          timed_perform(instance)
        ensure
          # Re-engage the flag so around_job middleware's after-yield region
          # can't resolve the job. The core block here is parsed as part of
          # run_chain's block argument, so this ensure runs as the
          # block exits — before middleware unwinds. Cleared again below
          # for handle_success.
          job._prevent_status_changes!
        end
        job._allow_status_changes!
        handle_success(job, result, configuration)
        result
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
          # Capture the failure on Resolution's error axis so after_job and
          # on_job_executed hooks see why complete! failed, even though the
          # error is logged-and-swallowed here. Symmetry with G2's early
          # capture in handle_perform_exception.
          job.send(:resolution).set_error(e)
          Busybee.logger&.warn("Failed to complete job #{job.key}: #{e.message}. Job will timeout and retry.")
        end
      end

      def handle_failure(job, error, config)
        return unless config.fail_job_on_error

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
        job.fail!(underlying_error(error), backoff: config.backoff)
      rescue StandardError => e
        Busybee.logger&.warn("Failed to fail job #{job.key}: #{e.message}. Job will timeout and retry.")
      end

      # When perform raises a Shutdown wrapping a triggering error, the
      # triggering error — not the wrapper — is what the engine and
      # Resolution should record. Returns the exception itself otherwise.
      def underlying_error(exception)
        exception.is_a?(Shutdown) ? (exception.cause || exception) : exception
      end

      def shutdown_error?(error, config)
        (config.shutdown_on + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
      end

      def log_unhandled_error(job, error)
        location = error.backtrace&.first
        suffix = location ? " (at #{location})" : ""
        Busybee.logger&.warn(
          "Unhandled error in #{configuration.job_type} worker for job #{job.key} " \
          "(fail_job_on_error is off): [#{error.class}] #{error.message}#{suffix}. " \
          "Job will timeout and retry."
        )
      end
    end
  end
end
