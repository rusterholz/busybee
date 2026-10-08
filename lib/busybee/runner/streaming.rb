# frozen_string_literal: true

require "concurrent"

require "busybee/client/call"
require "busybee/durations"
require "busybee/runner"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # Streaming runner — receives jobs via client.open_job_stream.
    # The stream continuously pushes newly-activated jobs from the gateway.
    # Note: streams only receive jobs created after the stream opens;
    # pre-existing jobs require polling to retrieve.
    #
    # Two modes:
    # - buffer: true (default) — A pump thread reads from the stream into a Queue;
    #   the main thread pops and processes sequentially. Better shutdown responsiveness
    #   and enables pump delay configuration.
    # - buffer: false — stream.each calls perform_job inline on the main thread.
    #   Simpler model for workers that don't need buffer features.
    class Streaming < Runner
      # @buffered_job_count tracks real jobs apart from Queue#size, so the depth
      # gauge ignores the :stop control sentinels the queue also carries.
      def initialize(worker_class, runtime_config: nil, client: nil)
        super
        return unless buffer?

        @job_buffer = Queue.new
        @buffered_job_count = Concurrent::AtomicFixnum.new(0)
        @peak_buffer_size = Concurrent::AtomicFixnum.new(0)
        @shutdown_error = Concurrent::AtomicReference.new(nil)
      end

      def kill!(...)
        super
        @pump_thread&.kill
        return unless buffer?

        report_discarded_jobs
        @job_buffer.clear
        @buffered_job_count.value = 0 # cleared queue holds no real jobs
        @job_buffer.push(:stop)
      end

      private

      # A kill discards these jobs and runs no job hooks to say so — a stuck
      # container is a poor place for adopter code. No worker hook fires either on
      # the real path: stop!'s set-once reason was won by the graceful stop, and
      # the CLI's exit! follows. So this is the only record work was dropped, and
      # it must precede the clear that drops it.
      def report_discarded_jobs
        discarded = @buffered_job_count.value
        return unless discarded.positive?

        Busybee.logger&.warn("[busybee] kill! discarded #{discarded} activated job(s) still buffered; " \
                             "the engine re-yields them when their activation times out")
      end

      # Fills Runner#run!'s loop: open the job stream and process jobs (via the
      # pump + buffer, or inline). Raises a worker Shutdown to signal an error exit.
      # The worker snapshot attributing the stream-open fetch goes stale over the
      # stream's life; execute-time re-seeding keeps the per-job worker current.
      def run_loop
        @stream = Client::Call.with_worker_status(worker_status) do
          @client.open_job_stream(job_type, job_timeout: @runtime_config.job_timeout)
        end

        if buffer?
          run_with_buffer
        else
          run_inline
        end
      end

      # Stop new jobs arriving: close the stream (unblocking stream.each via
      # GRPC::Cancelled) and drop the :stop sentinel that unblocks a blocking pop.
      # The single intake-cessation point — #stop! calls it before firing T1
      # (close-before-fire), and run!'s ensure again as the error-exit backstop.
      # Idempotent: a second close no-ops and extra sentinels are skipped on drain.
      def cease_intake
        @stream&.close
        @job_buffer&.push(:stop) if buffer?
      end

      # When buffered, join the pump thread and fail any jobs still in the buffer.
      def drain_on_shutdown
        return unless buffer?

        @pump_thread&.join(5)
        handle_remaining_jobs_in_buffer
      end

      def current_buffer_size
        return nil if @job_buffer.nil?

        @buffered_job_count.value
      end

      def peak_buffer_size
        return nil if @job_buffer.nil?

        @peak_buffer_size.value
      end

      # Buffer a real job, keeping @buffered_job_count in step with @job_buffer's
      # real jobs. Increment before the push so the gauge never under-reports, and
      # roll back if the push raises, so a failed push can't leak phantom depth.
      # (Deliberately not AtomicFixnum#update: under contention its block re-runs
      # in a CAS loop, which would double-push a side-effecting push.)
      #
      # Take the high-water from increment's own return value, not a later read —
      # a consumer pop on another thread can decrement between the push and the
      # peak update, so re-reading would miss the depth this push actually hit.
      def buffer_job(job)
        depth = @buffered_job_count.increment
        pushed = false
        begin
          @job_buffer.push(job)
          pushed = true
        ensure
          @buffered_job_count.decrement unless pushed
        end
        @peak_buffer_size.update { |peak| [peak, depth].max }
      end

      def run_with_buffer
        @pump_thread = Thread.new { pump_stream_into_buffer }
        process_buffered_jobs(blocking: true)

        err = @shutdown_error.get
        raise err if err
      end

      def run_inline
        shutdown_error = nil

        @stream.each do |job|
          activate_job(job, source: :stream)
          if stopping?
            handle_shutdown_job(job)
            break
          end

          execute_job(job)
        rescue Busybee::Worker::Shutdown => e
          shutdown_error = e
          declare_unhealthy(e)
          break
        end

        raise shutdown_error if shutdown_error
      end

      # Pump the stream into the buffer until stopped. Whatever ends the pump,
      # whatever its class, is stashed for the main thread to re-raise — so the
      # teardown classifies it as the run's exit error, skipping the drain below
      # RECOVERABLE_ERRORS — and stops with its discerned reason (Shutdown→
      # :unhealthy, gRPC→:gateway_error, else :crash) before the ensure's default
      # can mislabel it. Clean closes arrive as Cancelled and are absorbed.
      # The ensure is the backstop unblocking the main thread's blocking pop — a
      # no-op behind any earlier stop!, and reached live only by the gateway
      # closing the stream cleanly, which is what :gateway_closed names.
      def pump_stream_into_buffer
        delay = @runtime_config.buffer_throttle

        @stream.each do |job|
          break if stopping?

          activate_job(job, source: :stream, buffered: true)
          buffer_job(job)
          sleep(Busybee::Durations.seconds_from(delay)) if delay
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        @shutdown_error.update { |prev| prev || e }
        stop!(reason: reason_for(e))
      ensure
        stop!(reason: :gateway_closed)
      end

      # Process jobs from the buffer.
      # blocking: false — drains all currently-buffered jobs, returns if/when empty.
      # blocking: true  — blocks on pop until :stop sentinel or stopping?.
      def process_buffered_jobs(blocking:)
        loop do
          break if stopping?

          job = @job_buffer.pop(!blocking)
          break if job == :stop

          @buffered_job_count.decrement # a real job has left the buffer
          if stopping?
            handle_shutdown_job(job)
          else
            execute_job(job)
          end
        rescue ThreadError
          break # buffer empty (non-blocking only)
        rescue Busybee::Worker::Shutdown => e
          declare_unhealthy(e)
        end
      end

      # Drain remaining buffer during shutdown, failing all jobs.
      def handle_remaining_jobs_in_buffer
        loop do
          job = @job_buffer.pop(true) # non-blocking
          next if job == :stop

          @buffered_job_count.decrement # a real job has left the buffer
          handle_shutdown_job(job)
        rescue ThreadError
          break # buffer empty
        end
      end

      # First error wins; inline mode keeps its own, so has no reference to fill.
      def record_shutdown_error(error)
        @shutdown_error&.update { |prev| prev || error }
      end

      def buffer?
        @runtime_config.buffer
      end

      def job_type
        @worker_class.configuration.job_type
      end
    end
  end
end

# Direct subclass loads after the class body; it requires this file back.
require "busybee/runner/hybrid"
