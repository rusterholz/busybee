# frozen_string_literal: true

require "concurrent"

module Busybee
  # Base class for all runner types. Provides shared interface (run!, stop!, stopping?,
  # running?, kill!) and the Runner.for factory method for mode resolution.
  #
  # Subclasses must implement #run! to define their job-fetching loop.
  class Runner
    def initialize(worker_class = nil, runtime_config: nil, client: nil)
      @worker_class = worker_class
      @runtime_config = runtime_config
      @client = client || Busybee::Client.new
      @stop_requested = Concurrent::AtomicBoolean.new(false)
      @running = Concurrent::AtomicBoolean.new(false)
    end

    # Blocks until stopped or error. Subclasses must implement.
    def run!
      raise NotImplementedError
    end

    # Signals graceful shutdown. Thread-safe (called from signal handler).
    def stop!
      @stop_requested.make_true
    end

    # True if stop! has been called.
    def stopping?
      @stop_requested.true?
    end

    # True if run! is actively executing.
    def running?
      @running.true?
    end

    # Force shutdown. Base: calls stop!. Multi overrides to also kill thread pool.
    def kill!
      stop!
    end

    class << self
      # Factory method. Resolves worker mode via RuntimeConfig and returns
      # the appropriate runner instance.
      #
      # Mode resolution (lowest to highest priority):
      #   1. Gem default: Busybee.default_worker_mode
      #   2. Worker DSL: worker_class.configuration.worker_mode
      #   3. RuntimeConfig override (global or per-worker)
      def for(*worker_classes, runtime_config: nil, client: nil)
        runtime_config ||= RuntimeConfig.new
        client ||= Busybee::Client.new

        if worker_classes.length > 1
          Multi.new(worker_classes, runtime_config: runtime_config, client: client)
        else
          resolved = runtime_config.resolve_for(worker_classes.first)
          runner_class_for(resolved).new(worker_classes.first, runtime_config: resolved, client: client)
        end
      end

      private

      def runner_class_for(resolved_config)
        case resolved_config.worker_mode
        when :polling then Polling
        when :streaming then Streaming
        when :hybrid then Hybrid
        else
          raise ArgumentError,
                "Invalid worker mode: #{resolved_config.worker_mode.inspect}. Valid: :polling, :streaming, :hybrid"
        end
      end
    end

    private

    # Fails a job during graceful shutdown, preserving its retry count.
    # Uses the worker's configured backoff (or gem default).
    def handle_shutdown_job(job)
      job.fail!(
        "Worker shutting down",
        retries: job.retries,
        backoff: @runtime_config.backoff
      )
    rescue StandardError => e
      Busybee.logger&.warn("Failed to fail job #{job.key} during shutdown: #{e.message}")
    end

    # Stamp activation, capture source/buffer_size/worker_class on the Job,
    # and fire on_job_activated.
    #
    # @param job [Busybee::Job]
    # @param source [Symbol] :poll or :stream — which receive path activated this job
    # @param buffer_size [Integer, nil] queue depth at activation; nil iff
    #   the job will not be buffered. Buffered call sites must always pass a
    #   value (which may be 0); unbuffered sites must pass nil.
    def activate_job(job, source:, buffer_size: nil)
      job.timestamps.stamp!(:activated_at)
      job.set_context(source: source, buffer_size: buffer_size, worker_class: @worker_class)
      Hooks.run_on_job_activated(job)
    end

    # Run @worker_class.perform_job(job) inside the around_job_execution chain,
    # then (in ensure) refresh buffer_size, stamp executed_at, and fire
    # on_job_executed.
    #
    # @param job [Busybee::Job]
    def execute_job(job)
      Hooks.run_around_chain(:around_job_execution, job, safe: true) do
        @worker_class.perform_job(job)
      end
    ensure
      # Even with safe: true above, run_around_chain re-raises Shutdown so the
      # runner can tear down. This ensure runs executed_at + on_job_executed
      # even when the worker is shutting down, keeping observability of the
      # final activation intact.
      refresh_buffer_size!(job)
      job.timestamps.stamp!(:executed_at)
      Hooks.run_on_job_executed(job)
    end

    # Current depth of this runner's job buffer, or nil if the runner has
    # no buffer (Polling). Subclasses with a buffer override.
    def current_buffer_size
      nil
    end

    # Refresh job.activation.buffer_size to the runner's current queue depth,
    # so on_job_executed hooks see execution-time depth rather than the
    # receive-time depth captured at activation. No-op when the job was
    # never buffered (preserves the unbuffered invariant for polling jobs)
    # or when this runner has no buffer of its own to report.
    def refresh_buffer_size!(job)
      return if job.buffer_size.nil? || current_buffer_size.nil?

      job.set_context(buffer_size: current_buffer_size)
    end
  end
end

require "busybee/runner/polling"
require "busybee/runner/streaming"
require "busybee/runner/hybrid"
require "busybee/runner/multi"
