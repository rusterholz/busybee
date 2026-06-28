# frozen_string_literal: true

require "concurrent"

module Busybee
  # Base class for all runner types. Provides the shared lifecycle (run!, stop!,
  # stopping?, running?, kill!) and the Runner.for factory for mode resolution.
  #
  # #run! is a template method owning the worker run lifecycle (started → loop →
  # stopping → drain → shutdown). Subclasses implement #run_loop (the fetch loop)
  # and optionally #drain_on_shutdown (graceful drain). Multi overrides #run! to
  # opt out — it manages child runners rather than being a worker itself.
  class Runner
    def initialize(worker_class = nil, runtime_config: nil, client: nil)
      @worker_class = worker_class
      @runtime_config = runtime_config
      @client = client || Busybee::Client.new
      @stop_requested = Concurrent::AtomicBoolean.new(false)
      @running = Concurrent::AtomicBoolean.new(false)
    end

    # Template method owning the worker run lifecycle. Blocks until the runner
    # is stopped or #run_loop raises. The ensure runs on every exit path (signal,
    # error, normal return), on the runner thread.
    def run!
      return if stopping?

      @running.make_true
      # [hook: runner.started]
      run_loop
    ensure
      cease_intake
      # [hook: runner.stopping]
      drain_on_shutdown
      # [hook: runner.shutdown]
      @running.make_false
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

    # The fetch/process loop. Fills Runner#run!'s body between on_worker_started
    # and the stopping/drain/shutdown ensure; raises to signal an error exit.
    def run_loop
      raise NotImplementedError
    end

    # Cease intake — the first step in Runner#run!'s ensure, before
    # on_worker_stopping fires (close-before-fire), so a misbehaving stopping
    # observer can never leave the job stream open and wedge shutdown. No-op by
    # default (polling has no stream); streaming overrides to close the stream.
    # Idempotent with stop!'s own close on the graceful path; the real close for
    # the uncaught-error exit path (where stop! was never called).
    def cease_intake; end

    # Graceful drain — runs in Runner#run!'s ensure, between on_worker_stopping
    # and on_worker_shutdown, on every exit path. No-op by default (polling has
    # nothing to drain); buffering subclasses override to join the pump and fail
    # any jobs still sitting in the buffer.
    def drain_on_shutdown; end

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
      Hooks.run(:on_job_activated, job, safe: true)
    end

    # Run @worker_class.perform_job(job) inside the around_job_execution chain,
    # then (in ensure) refresh buffer_size, stamp executed_at, and fire
    # on_job_executed.
    #
    # @param job [Busybee::Job]
    def execute_job(job)
      Hooks.run_chain(:around_job_execution, job, safe: true) do
        @worker_class.perform_job(job)
      end
    ensure
      # Even with safe: true above, run_chain re-raises Shutdown so the
      # runner can tear down. This ensure runs executed_at + on_job_executed
      # even when the worker is shutting down, keeping observability of the
      # final activation intact.
      refresh_buffer_size!(job)
      job.timestamps.stamp!(:executed_at)
      Hooks.run(:on_job_executed, job, safe: true)
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
