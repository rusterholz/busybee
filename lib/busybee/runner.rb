# frozen_string_literal: true

require "concurrent"

require "busybee/client"
require "busybee/durations"
require "busybee/grpc/error"
require "busybee/hooks"
require "busybee/runtime_config"
require "busybee/worker/shutdown"
require "busybee/worker/status"

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
      @stop_reason = Concurrent::AtomicReference.new(nil)
      @running = Concurrent::AtomicBoolean.new(false)
      @worker_timestamps = Worker::Timestamps.new
      @total_job_count = Concurrent::AtomicFixnum.new(0)
      @failed_job_count = Concurrent::AtomicFixnum.new(0)
      @backpressure_count = Concurrent::AtomicFixnum.new(0)
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
        exception = $!
        error = Busybee::Worker::Shutdown.unwrap(exception)
        # Discern a reason only from a real exit exception; compare_and_set no-ops
        # when stop! already won the gate, so a caller reason (:sigterm, :rollover,
        # :unhealthy) survives a coexisting error. Never fabricated — a clean exit
        # carries only the reason stop! set (its :signal default).
        @stop_reason.compare_and_set(nil, reason_for(exception)) if exception
        fire_worker_lifecycle(:stopping_at, :on_worker_stopping, error)
        drain_on_shutdown
        fire_worker_lifecycle(:shutdown_at, :on_worker_shutdown, error)
        @running.make_false
      end
    end

    # Signals graceful shutdown, recording why. Thread-safe (called from a signal
    # handler — the CLI runs the handler on its own thread, so this is never raw
    # trap context). The reason IS the gate: compare_and_set(nil, reason) both
    # stores it set-once and reports whether this call won, so "is-stopping" and
    # "the reason" are one atomic fact (no window where stopping? is true but the
    # reason unset) and T1 fires exactly once across repeated signals / per-job
    # Shutdowns. Intake ceases (cease_intake) *before* the hook fires, so a
    # propagating observer can never skip the close and wedge shutdown
    # (close-before-fire). reason is a low-cardinality Symbol — see docs/internal.
    def stop!(reason: :signal)
      raise ArgumentError, "stop reason must be a Symbol, got #{reason.class}" unless reason.is_a?(Symbol)
      return unless @stop_reason.compare_and_set(nil, reason)

      @worker_timestamps.stamp!(:stop_requested_at)
      cease_intake
      Hooks.run(:on_worker_stop_requested, worker_status, safe: true)
    end

    # True if stop! has been called.
    def stopping? = !@stop_reason.get.nil?

    # True if run! is actively executing.
    def running? = @running.true?

    # Force shutdown. Base: stop with :kill. Multi overrides to also kill the pool.
    def kill! = stop!(reason: :kill)

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
    # all-or-none. error is the classified in-flight exception, shared by both
    # moments; reason is read off @stop_reason by worker_status.
    def fire_worker_lifecycle(stamp, type, error)
      @worker_timestamps.stamp!(stamp)
      Hooks.run(type, worker_status(error: error), safe: true)
    end

    # Handle a wrapped gRPC error raised by a fetch loop. The *outcome* is matched
    # by status symbol (grpc_status) against Busybee.backpressure_statuses —
    # independent of which gRPC exception class the gateway raised. A backpressure
    # outcome backs off and returns, so the loop retries the fetch; any other gRPC
    # error re-raises and propagates. The delay is configured in milliseconds and
    # Kernel#sleep takes seconds, so it converts here — the one place it is read.
    def handle_grpc_error(error)
      raise error unless Busybee.backpressure_statuses.include?(error.grpc_status)

      @backpressure_count.increment
      sleep Busybee::Durations.seconds_from(@runtime_config.backpressure_delay)
    end

    # Discern a stop reason from an exit error (never fabricated — the only
    # presumption is stop!'s :signal default). A Worker::Shutdown is the worker
    # declaring itself down (:unhealthy); an unrecovered gRPC failure means busybee
    # couldn't reach the engine (:gateway_error); anything else is an internal
    # defect (:crash). reason ⊥ error — this names the trigger; the exception rides
    # the separate error axis. Shared by run!'s ensure, the streaming pump, and
    # Multi's crash cascade. The gateway_* prefix groups the engine-driven endings
    # (with :gateway_closed) as a filterable family, like sig*.
    def reason_for(error)
      case error
      when Busybee::Worker::Shutdown then :unhealthy
      when Busybee::GRPC::Error then :gateway_error
      else :crash
      end
    end

    # Build a fresh, point-in-time Worker::Status snapshot — the carrier handed
    # to worker hooks and stamped into job context for job-hook visibility. Reads
    # the set-once stop reason off @stop_reason, so every snapshot (lifecycle and
    # per-job) reports one consistent value; error is the exit exception, known
    # only in the ensure.
    def worker_status(error: nil)
      Worker::Status.new(
        worker_class: @worker_class,
        worker_mode: @runtime_config&.worker_mode,
        timestamps: @worker_timestamps,
        total_job_count: @total_job_count.value,
        failed_job_count: @failed_job_count.value,
        backpressure_count: @backpressure_count.value,
        current_buffer_size: current_buffer_size,
        peak_buffer_size: peak_buffer_size,
        reason: @stop_reason.get,
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
    # Uses the worker's configured fail_job_backoff (or gem default).
    def handle_shutdown_job(job)
      with_fresh_worker_status(job) do
        job.fail!(
          "Worker shutting down",
          retries: job.retries,
          backoff: @runtime_config.fail_job_backoff
        )
      end
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
      job.set_context(source: source, buffered: buffered, worker_class: @worker_class)
      with_fresh_worker_status(job) do
        Hooks.run(:on_job_activated, job, safe: true)
      end
    end

    # Open a worker window over a job: stamp a fresh point-in-time Worker::Status
    # onto the job, then seed that SAME object for Calls via Call.with_worker_status.
    # Reading it back off the job (rather than passing worker_status twice) is what
    # guarantees a Call can never correlate to two statuses — the one it folds and
    # job.worker_status are one object. Each window re-stamps, so its gauges read as
    # of that moment. Worker only, never job: job is the perform-only carrier
    # (Worker.perform_job); lifecycle hooks and around_job_execution middleware hold
    # the Job directly.
    def with_fresh_worker_status(job, &)
      job.set_context(worker_status: worker_status)
      Client::Call.with_worker_status(job.worker_status, &)
    end

    # Run @worker_class.perform_job(job) inside the around_job_execution chain,
    # then (in ensure) stamp executed_at and fire on_job_executed.
    #
    # @param job [Busybee::Job]
    def execute_job(job)
      with_fresh_worker_status(job) do
        # Always descends, even for a job an on_job_activated hook already
        # resolved: middleware brackets every job that was activated, and only
        # the innermost gate decides whether work happens.
        Hooks.run_chain(:around_job_execution, job, safe: true) do
          @worker_class.perform_job(job) # seeds its own job carrier (Call.with_job) for perform
        end
      ensure
        # Runs even under run_chain's Shutdown re-raise, so the final activation
        # stays observable during teardown. A second window re-stamps: on_job_executed
        # reads gauges/counters as of completion, not the (possibly long-ago) start.
        job.timestamps.stamp!(:executed_at)
        @total_job_count.increment
        @failed_job_count.increment if job.failed?
        with_fresh_worker_status(job) do
          Hooks.run(:on_job_executed, job, safe: true)
        end
      end
    end

    # Current depth of this runner's job buffer, or nil if the runner has no
    # buffer (Polling). Subclasses with a buffer override. The buffer-depth
    # gauge — read into Worker::Status for worker- and job-hook visibility.
    def current_buffer_size = nil

    # Lifetime high-water mark of this runner's job buffer, or nil if the runner
    # has no buffer (Polling). Buffering subclasses override. Read into
    # Worker::Status alongside current_buffer_size.
    def peak_buffer_size = nil
  end
end

# Direct subclasses load after the class body; each requires this file back.
# Hybrid rides at the bottom of streaming.rb — it subclasses Streaming.
require "busybee/runner/multi"
require "busybee/runner/polling"
require "busybee/runner/streaming"
