# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "busybee/worker/configuration"
require "busybee/worker/dsl"

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
    # Raised when a `shutdown_on` exception is caught during perform_job.
    # Signals to the Runner that the worker process should shut down.
    # The original exception is available via `cause` (set by Ruby at raise time).
    class Shutdown < Busybee::Error
      attr_reader :worker_class

      def initialize(message = "Shutting down worker #{Busybee.worker_name}", worker:)
        @worker_class = worker
        super(message)
      end

      def message
        super.dup.tap do |msg|
          msg << " due to #{cause&.class&.name || 'error'}"
          msg << " in #{worker_class.name}" if worker_class&.name
          msg << ": \"#{cause.message}\"" if cause
        end
      end
    end

    extend DSL

    attr_reader :job

    delegate :variables, :headers, :complete!, :fail!, :throw_bpmn_error!,
             :update_retries, :update_timeout, to: :job

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
      # @return [Object] The return value of perform (useful for testing)
      # @raise [Busybee::Worker::Shutdown] if a shutdown_on exception is caught
      def perform_job(job)
        config = configuration
        instance = new(job)
        # [hook: job.started]
        begin
          validate_inputs!(instance, config)
          result = instance.perform
          handle_success(job, result, config)
          result
        rescue StandardError => e
          handle_failure(job, e, config)
          raise if e.is_a?(Shutdown)
          raise Shutdown.new(worker: self) if shutdown_error?(e, config)

          log_unhandled_error(job, e) unless config.fail_job_on_error
        ensure # rubocop:disable Lint/EmptyEnsure
          # [hook: job.finished]
        end
      end

      private

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
        validate_outputs!(new_vars, config)
        begin
          job.complete!(new_vars)
        rescue StandardError => e
          Busybee.logger&.warn("Failed to complete job #{job.key}: #{e.message}. Job will timeout and retry.")
        end
      end

      def validate_outputs!(result, config)
        missing = config.outputs.select(&:required).reject { |o| result.key?(o.name) || result.key?(o.name.to_s) }
        return if missing.empty?

        names = missing.map { |o| ":#{o.name}" }.join(", ")
        raise Busybee::MissingOutput, "Missing required outputs for #{configuration.job_type} worker: #{names}"
      end

      def handle_failure(job, error, config)
        return unless config.fail_job_on_error && job.ready?

        fail_with = error.is_a?(Shutdown) ? (error.cause || error) : error
        begin
          job.fail!(fail_with, backoff: config.backoff)
        rescue StandardError => e
          Busybee.logger&.warn("Failed to fail job #{job.key}: #{e.message}. Job will timeout and retry.")
        end
      end

      def shutdown_error?(error, config)
        (config.shutdown_on + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
      end

      def log_unhandled_error(job, error)
        Busybee.logger&.warn(
          "Unhandled error in #{configuration.job_type} worker for job #{job.key} " \
          "(fail_job_on_error is off): [#{error.class}] #{error.message}. Job will timeout and retry."
        )
      end
    end
  end
end
