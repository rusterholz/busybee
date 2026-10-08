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
      # The thread variable naming the runner a pump thread pumps for.
      PUMP_OWNER = :"busybee.runner.streaming.pump_owner"
      private_constant :PUMP_OWNER

      # @buffered_job_count tracks real jobs apart from Queue#size, so the depth
      # gauge ignores the :stop control sentinels the queue also carries.
      def initialize(worker_class, runtime_config: nil, client: nil)
        super
        return unless buffer?

        @job_buffer = Queue.new
        @buffered_job_count = Concurrent::AtomicFixnum.new(0)
        @peak_buffer_size = Concurrent::AtomicFixnum.new(0)
        @shutdown_error = Concurrent::AtomicReference.new(nil)
        @late_pump_error = Concurrent::AtomicReference.new(nil)
        @pump_claim = Mutex.new
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

      # When buffered, join the pump thread and hand back the jobs still buffered.
      # After a pump error like NoMemoryError they stay put, and the engine's
      # activation timeout returns them.
      def drain_on_shutdown
        return unless buffer?

        @pump_thread&.join(5)
        return unless pump_errors.all? { |error| recoverable?(error) } # no wire calls from a dying process

        handle_remaining_jobs_in_buffer
      end

      def pump_errors = [@shutdown_error.get, @late_pump_error.get].compact
      def late_error = @late_pump_error&.get
      def current_buffer_size = @buffered_job_count&.value
      def peak_buffer_size = @peak_buffer_size&.value

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
        raise_exit_error
      end

      # Called once the loop has seen a stop; the lock waits out a pump still
      # recording the error behind its claim.
      def raise_exit_error
        err = @pump_claim.synchronize { @shutdown_error.get }
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
      # whatever its class, goes to end_pump under its discerned reason
      # (Shutdown→:unhealthy, gRPC→:gateway_error, else :crash), ahead of the
      # ensure's default. Clean closes arrive as Cancelled and are absorbed. The
      # ensure is the backstop unblocking the main thread's blocking pop: a no-op
      # behind any earlier stop!, and reached live only by the gateway closing
      # the stream cleanly, which is what :gateway_closed names.
      def pump_stream_into_buffer
        Thread.current.thread_variable_set(PUMP_OWNER, self)
        delay = @runtime_config.buffer_throttle

        @stream.each do |job|
          break if stopping?

          activate_job(job, source: :stream, buffered: true)
          buffer_job(job)
          sleep(Busybee::Durations.seconds_from(delay)) if delay
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        end_pump(e, reason_for(e))
      ensure
        stop!(reason: :gateway_closed)
      end

      # An error whose claim wins the stop reason caused the stop: the main
      # thread raises it as the run's exit error. One meeting a stop already
      # under way is late: never raised, the winning reason stands, and T3
      # reports it. A winner finding the exit slot taken goes late too, so no
      # pump error is lost. A Shutdown from activation arrives twice, declared
      # and then re-raised; the first record stands.
      def end_pump(error, reason)
        return if pump_errors.any? { |recorded| recorded.equal?(error) }

        won = @pump_claim.synchronize do # else raise_exit_error could see the stop before the record
          claimed = @stop_reason.compare_and_set(nil, reason)
          exiting = claimed && @shutdown_error.compare_and_set(nil, error)
          @late_pump_error.compare_and_set(nil, error) unless exiting
          claimed
        end
        announce_stop if won
      end

      # On the pump, a hook declaring the worker down ends the pump like any error.
      def declare_unhealthy(error)
        pumping? ? end_pump(error, :unhealthy) : super
      end

      def pumping? = Thread.current.thread_variable_get(PUMP_OWNER).equal?(self)

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
      def record_shutdown_error(error) = @shutdown_error&.update { |prev| prev || error }
      def buffer? = @runtime_config.buffer
      def job_type = @worker_class.configuration.job_type
    end
  end
end

# Direct subclass loads after the class body; it requires this file back.
require "busybee/runner/hybrid"
