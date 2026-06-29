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
      @worker_timestamps = Worker::Timestamps.new
    end

    # Template method owning the worker run lifecycle. Blocks until the runner
    # is stopped or #run_loop raises. Once a run is accepted, the ensure runs on
    # every exit path (signal, error, normal return), on the runner thread.
    #
    # Fires the worker-lifecycle hooks at three of the four moments — started
    # (T0, here), stopping (T2) and shutdown (T3, in the ensure); stop_requested
    # (T1) fires from #stop! on the signalling thread. Each fires with a fresh
    # Worker::Status.
    #
    # Single-entry: start! flips @running with an atomic compare-and-set and
    # reports whether this call won it, so a second run! while one is already
    # active is a no-op — without it, two callers would each block their own
    # run_loop. The `return unless start!` sits before the begin/ensure so a
    # rejected entry (and the `return if stopping?` early-exit) returns without
    # running the teardown — which is also what makes the T0/T2/T3 set fire
    # all-or-none: the ensure is reached only once start! has succeeded.
    def run!
      return if stopping?
      return unless start!

      begin
        run_loop
      ensure
        cease_intake
        reason, error = classify_exit($!)
        fire_worker_lifecycle(:stopping_at, :on_worker_stopping, reason, error)
        drain_on_shutdown
        fire_worker_lifecycle(:shutdown_at, :on_worker_shutdown, reason, error)
        @running.make_false
      end
    end

    # Signals graceful shutdown. Thread-safe (called from a signal handler — the
    # CLI runs the handler on its own thread, so this is never raw trap context).
    # The AtomicBoolean CAS gates the whole body, so T1 fires exactly once across
    # repeated signals / per-job Shutdowns. Intake ceases (cease_intake) *before*
    # the hook fires, so a propagating observer can never skip the close and wedge
    # shutdown (close-before-fire).
    def stop!
      return unless @stop_requested.make_true

      @worker_timestamps.stamp!(:stop_requested_at)
      cease_intake
      Hooks.run(:on_worker_stop_requested, worker_status, safe: true)
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

    # T0 — try to begin the run. The @running flip is an atomic compare-and-set
    # that doubles as the single-entry gate: lose it (a run is already active)
    # and start! returns false at once, BEFORE stamping or firing — so a rejected
    # re-entry can't overwrite started_at or re-announce. On winning the flip,
    # stamp the moment, announce via on_worker_started, and return true.
    def start! # rubocop:disable Naming/PredicateMethod
      return false unless @running.make_true

      @worker_timestamps.stamp!(:started_at)
      Hooks.run(:on_worker_started, worker_status, safe: true)
      true
    end

    # Stamp a closing lifecycle moment (T2 stopping / T3 shutdown) and fire its
    # observation-only hook with a fresh Status. Reached only from run!'s ensure,
    # which runs only after start! won the entry, so the T0/T2/T3 set is
    # all-or-none. reason/error are the classified in-flight exception, shared by
    # both moments.
    def fire_worker_lifecycle(stamp, type, reason, error)
      @worker_timestamps.stamp!(stamp)
      Hooks.run(type, worker_status(reason: reason, error: error), safe: true)
    end

    # Handle a wrapped gRPC error raised by a fetch loop. The *outcome* is matched
    # by status symbol (grpc_status) against Busybee.backpressure_statuses —
    # independent of which gRPC exception class the gateway raised. A backpressure
    # outcome backs off (sleeps the configured delay) and returns, so the loop
    # retries the fetch; any other gRPC error re-raises and propagates.
    def handle_grpc_error(error)
      raise error unless Busybee.backpressure_statuses.include?(error.grpc_status)

      sleep @runtime_config.backpressure_delay
    end

    # Classify the run's exit from the in-flight exception ($! in the ensure):
    # no exception → a clean stop signal; a Worker::Shutdown → an error reported
    # as its triggering cause; any other exception → an error reported as-is
    # (covers the raw activation-path fatal that exits run! unwrapped).
    def classify_exit(exception)
      case exception
      when nil then [:signal, nil]
      when Busybee::Worker::Shutdown then [:error, exception.cause]
      else [:error, exception]
      end
    end

    # Build a fresh, point-in-time Worker::Status snapshot — the carrier handed
    # to worker hooks and stamped into job context for job-hook visibility.
    def worker_status(reason: nil, error: nil)
      Worker::Status.new(
        worker_class: @worker_class,
        worker_mode: @runtime_config&.worker_mode,
        timestamps: @worker_timestamps,
        current_buffer_size: current_buffer_size,
        peak_buffer_size: peak_buffer_size,
        reason: reason,
        error: error
      )
    end

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

    # Stamp activation, capture source/buffered/worker_class on the Job, and
    # fire on_job_activated.
    #
    # @param job [Busybee::Job]
    # @param source [Symbol] :poll or :stream — which receive path activated this job
    # @param buffered [Boolean] whether this job came through a runner buffer.
    #   Buffered call sites pass true; direct (poll/inline) sites leave it false.
    def activate_job(job, source:, buffered: false)
      job.timestamps.stamp!(:activated_at)
      job.set_context(source: source, buffered: buffered, worker_class: @worker_class,
                      worker_status: worker_status)
      Hooks.run(:on_job_activated, job, safe: true)
    end

    # Run @worker_class.perform_job(job) inside the around_job_execution chain,
    # then (in ensure) stamp executed_at and fire on_job_executed.
    #
    # @param job [Busybee::Job]
    def execute_job(job)
      # Re-stamp a fresh Status: the buffer gauge may have moved since activation,
      # and execution-time is the heartbeat job hooks read job.worker_status at.
      job.set_context(worker_status: worker_status)
      Hooks.run_chain(:around_job_execution, job, safe: true) do
        @worker_class.perform_job(job)
      end
    ensure
      # Even with safe: true above, run_chain re-raises Shutdown so the
      # runner can tear down. This ensure runs executed_at + on_job_executed
      # even when the worker is shutting down, keeping observability of the
      # final activation intact.
      job.timestamps.stamp!(:executed_at)
      Hooks.run(:on_job_executed, job, safe: true)
    end

    # Current depth of this runner's job buffer, or nil if the runner has no
    # buffer (Polling). Subclasses with a buffer override. The buffer-depth
    # gauge — read into Worker::Status for worker- and job-hook visibility.
    def current_buffer_size
      nil
    end

    # Lifetime high-water mark of this runner's job buffer, or nil if the runner
    # has no buffer (Polling). Buffering subclasses override. Read into
    # Worker::Status alongside current_buffer_size.
    def peak_buffer_size
      nil
    end
  end
end

require "busybee/runner/polling"
require "busybee/runner/streaming"
require "busybee/runner/hybrid"
require "busybee/runner/multi"
