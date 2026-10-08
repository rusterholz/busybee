# frozen_string_literal: true

require "concurrent"

require "busybee/client"
require "busybee/durations"
require "busybee/grpc/error"
require "busybee/hooks"
require "busybee/runner/teardown"
require "busybee/runtime_config"
require "busybee/worker/shutdown"
require "busybee/worker/status"

module Busybee
  # Base class for all runner types: the shared lifecycle, the Runner.for factory,
  # and #run! as a template method (started → loop → stopping → drain → shutdown)
  # that subclasses fill via #run_loop and optionally #drain_on_shutdown. Multi
  # overrides #run! — it manages child runners rather than being a worker.
  class Runner
    # Errors after which tearing down gracefully is still worth attempting; below
    # it, drop work and leave fast. Deliberately NOT shared with the identically-
    # named constant on Client::Call — they coincide today but ask different
    # questions (record fidelity there, teardown viability here), so widening one
    # must not silently decide the other. Same name so one grep finds both.
    RECOVERABLE_ERRORS = [StandardError].freeze

    include Teardown

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
      @teardown_error = Concurrent::AtomicReference.new(nil)
    end

    # Blocks until stopped or until #run_loop raises; the teardown then runs on every
    # exit path, on the runner thread. Fires T0 here and T2/T3 in the teardown, each
    # with a fresh Worker::Status; T1 fires from #stop!. Single-entry: start!'s
    # compare-and-set reports whether this call won, so a second run! is a no-op —
    # and sitting before the begin/ensure makes T0/T2/T3 all-or-none.
    def run!
      return if stopping?
      return unless start!

      begin
        run_loop
      ensure
        teardown($!)
      end
    end

    # Signals graceful shutdown, recording why. Thread-safe — the CLI runs signal
    # handlers on their own thread. The reason IS the gate: set-once, and reporting
    # whether this call won, so "is-stopping" and "the reason" are one atomic fact
    # and T1 fires once. Intake ceases *before* the hook (close-before-fire).
    def stop!(reason: :signal)
      raise ArgumentError, "stop reason must be a Symbol, got #{reason.class}" unless reason.is_a?(Symbol)
      return unless @stop_reason.compare_and_set(nil, reason)

      @worker_timestamps.stamp!(:stop_requested_at)
      cease_intake
      contain_teardown_escalation(:on_worker_stop_requested) do
        Hooks.run(:on_worker_stop_requested, worker_status, safe: true)
      end
    end

    # True if stop! has been called.
    def stopping? = !@stop_reason.get.nil?

    # True if run! is actively executing.
    def running? = @running.true?

    # Force shutdown; Multi overrides to also kill the pool. Parameterised because
    # a hard teardown is not always operator-initiated (see Multi's cascade).
    def kill!(reason: :kill) = stop!(reason: reason)

    class << self
      # Resolves worker mode and returns the matching runner. Mode precedence,
      # lowest first: Busybee.default_worker_mode, the worker DSL's worker_mode,
      # then a RuntimeConfig override (global or per-worker).
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

    # T0 — try to begin the run. The @running flip doubles as the single-entry
    # gate: lose it and start! returns false BEFORE stamping or firing.
    def start! # rubocop:disable Naming/PredicateMethod
      return false unless @running.make_true

      @worker_timestamps.stamp!(:started_at)
      Hooks.run(:on_worker_started, worker_status, safe: true)
      true
    end

    # A fetch loop's wrapped gRPC error, matched by grpc_status against
    # Busybee.backpressure_statuses whatever class the gateway raised: backpressure
    # backs off so the loop retries, anything else propagates. ms→s converts here.
    def handle_grpc_error(error)
      raise error unless Busybee.backpressure_statuses.include?(error.grpc_status)

      @backpressure_count.increment
      sleep Busybee::Durations.seconds_from(@runtime_config.backpressure_delay)
    end

    # Discern a stop reason from an exit error, never fabricated. reason ⊥ error:
    # this names the trigger, the exception rides its own axis. gateway_* groups the
    # engine-driven endings as a filterable family, like sig*.
    def reason_for(error)
      case error
      when Busybee::Worker::Shutdown then :unhealthy
      when Busybee::GRPC::Error then :gateway_error
      else :crash
      end
    end

    # A fresh point-in-time snapshot: the carrier worker hooks receive and job
    # context carries. The set-once reason means every snapshot agrees.
    def worker_status(error: nil)
      Worker::Status.new(
        worker_class: @worker_class,
        worker_mode: worker_mode,
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

    def worker_mode = @runtime_config&.worker_mode

    # The fetch/process loop, filling run!'s body between T0 and the ensure.
    def run_loop = raise(NotImplementedError)

    # First step of run!'s ensure, before T2 fires (close-before-fire), so no
    # observer can leave the stream open and wedge shutdown. Streaming overrides;
    # idempotent, and the real close where stop! was never called.
    def cease_intake; end

    # Runs between T2 and T3 on every exit path. Buffering subclasses override to
    # join the pump and hand back jobs still sitting in the buffer.
    def drain_on_shutdown; end

    # Hand a job back to the engine unworked, then say so. Worker-lifecycle work,
    # so a failure rides the worker carrier — the job did nothing, reports nothing.
    # Firing from the ensure means the hook fires however the handback went.
    def handle_shutdown_job(job)
      error = nil
      with_fresh_worker_status(job) { return_job_unworked(job) }
    rescue StandardError => e
      error = e
      Busybee.logger&.warn("Failed to hand job #{job.key} back during shutdown: #{e.message}")
    ensure
      with_fresh_worker_status(job, error: error) do
        Hooks.run(:on_job_not_executed, job, safe: true)
      end
    end

    # Deliberately not Job#fail!: handed back, not failed, so nothing is resolved
    # and status stays :ready — :failed would look like a job that ran and lost.
    def return_job_unworked(job)
      Client::Call.with_job(job) do
        @client.fail_job(job.key, "Worker shutting down",
                         retries: job.retries, backoff: @runtime_config.fail_job_backoff)
      end
    end

    # Stamp activation, capture source/buffered/worker_class, fire on_job_activated.
    # A hook declaring the worker down leaves this job in hand and unworked, so it
    # goes back as any job in hand at a stop does, then the escalation carries on.
    #
    # @param job [Busybee::Job]
    # @param source [Symbol] :poll or :stream — the receive path that activated it
    # @param buffered [Boolean] true from buffered call sites, false from direct ones
    def activate_job(job, source:, buffered: false)
      job.timestamps.stamp!(:activated_at)
      job.set_context(source: source, buffered: buffered, worker_class: @worker_class)
      with_fresh_worker_status(job) do
        Hooks.run(:on_job_activated, job, safe: true)
      end
    rescue Busybee::Worker::Shutdown => e
      declare_unhealthy(e)
      handle_shutdown_job(job)
      raise
    end

    # The worker declared itself down: keep the error for run! to re-raise, then
    # stop. Recording first matters on the pump, whose stop wakes the main thread.
    def declare_unhealthy(error)
      record_shutdown_error(error)
      stop!(reason: :unhealthy)
    end

    def record_shutdown_error(_error); end

    # Stamp a fresh Status onto the job, then seed that SAME object for Calls —
    # reading it back off the job rather than passing it twice is what stops a Call
    # correlating to two statuses. Each window re-stamps, so gauges are current.
    def with_fresh_worker_status(job, error: nil, &)
      job.set_context(worker_status: worker_status(error: error))
      Client::Call.with_worker_status(job.worker_status, &)
    end

    # perform_job inside the around_job_execution chain; the ensure then stamps
    # executed_at and fires on_job_executed. The chain always descends, even for a
    # job a hook already resolved — middleware brackets every activated job, and
    # only the innermost gate decides whether work happens. The ensure runs even
    # under run_chain's Shutdown re-raise, and re-stamps, so the final activation
    # stays observable and its gauges read as of completion.
    #
    # @param job [Busybee::Job]
    def execute_job(job)
      with_fresh_worker_status(job) do
        Hooks.run_chain(:around_job_execution, job, safe: true) do
          @worker_class.perform_job(job) # seeds its own job carrier (Call.with_job) for perform
        end
      ensure
        job.timestamps.stamp!(:executed_at)
        @total_job_count.increment
        @failed_job_count.increment if job.failed?
        with_fresh_worker_status(job) do
          Hooks.run(:on_job_executed, job, safe: true)
        end
      end
    end

    # Buffer depth and its lifetime high-water mark, or nil where there is no
    # buffer (Polling). Buffering subclasses override; both feed Worker::Status.
    def current_buffer_size = nil
    def peak_buffer_size = nil
  end
end

# Direct subclasses load after the class body; each requires this file back.
# Hybrid rides at the bottom of streaming.rb — it subclasses Streaming.
require "busybee/runner/multi"
require "busybee/runner/polling"
require "busybee/runner/streaming"
