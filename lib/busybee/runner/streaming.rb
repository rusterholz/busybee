# frozen_string_literal: true

require "concurrent"
require "monitor"

require "busybee/client/call"
require "busybee/durations"
require "busybee/error"
require "busybee/grpc/error"
require "busybee/logging"
require "busybee/runner"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # Streaming runner: receives jobs via client.open_job_stream.
    # The stream continuously pushes newly-activated jobs from the gateway.
    # Note: streams only receive jobs created after the stream opens;
    # pre-existing jobs require polling to retrieve.
    #
    # Two modes:
    # - buffer: true (default). A pump thread reads from the stream into a Queue;
    #   the main thread pops and processes sequentially. Better shutdown responsiveness
    #   and enables pump delay configuration.
    # - buffer: false. stream.each calls perform_job inline on the main thread.
    #   Simpler model for workers that don't need buffer features.
    class Streaming < Runner
      # @buffered_job_count tracks real jobs apart from Queue#size, so the depth
      # gauge ignores the :stop control sentinels the queue also carries.
      def initialize(worker_class, runtime_config: nil, client: nil)
        super
        @stop_lock = Monitor.new # the stop claim's slots, assigning @stream, and closing it
        return unless buffer?

        @job_buffer = Queue.new
        @buffered_job_count = Concurrent::AtomicFixnum.new(0)
        @peak_buffer_size = Concurrent::AtomicFixnum.new(0)
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

      # A kill discards these jobs and runs no job hooks to say so. No worker hook
      # fires either on the real path: stop!'s set-once reason was won by the
      # graceful stop, and the CLI's exit! follows. So this is the only record work
      # was dropped, and it must precede the clear that drops it.
      def report_discarded_jobs
        discarded = @buffered_job_count.value
        return unless discarded.positive?

        Logging.warn("kill! discarded #{discarded} activated job(s) still buffered by #{logged_worker_name}; " \
                     "the engine re-yields them when their activation times out", worker_status)
      end

      # Fills Runner#run!'s loop: open the job stream and process jobs (via the
      # pump + buffer, or inline). Raises a worker Shutdown to signal an error exit.
      # The worker snapshot attributing the stream-open fetch goes stale over the
      # stream's life; execute-time re-seeding keeps the per-job worker current.
      # A stop sets its reason before cease_intake takes the lock, so a stop whose
      # close found no stream shows at the check, and a later one closes it unread.
      def run_loop
        stream = Client::Call.with_worker_status(worker_status) do
          @client.open_job_stream(job_type, job_timeout: @runtime_config.job_timeout)
        end
        @stop_lock.synchronize { @stream = stream }
        return if stopping? # a stop as it opened found no stream: the teardown's cease_intake closes it

        if buffer?
          run_with_buffer
        else
          run_inline
        end
      end

      # Stop new jobs arriving: close the stream (unblocking stream.each via
      # GRPC::Cancelled) and drop the :stop sentinel that unblocks a blocking pop.
      # The single intake-cessation point: announce_stop calls it before firing T1
      # (close-before-fire), and run!'s ensure again as the error-exit backstop.
      # Idempotent: a second close no-ops and extra sentinels are skipped on drain.
      def cease_intake
        @stop_lock.synchronize { @stream&.close }
        @job_buffer&.push(:stop) if buffer?
      end

      # Only our own close makes a stream refuse its first read, so that is a
      # clean end like any other.
      def each_streamed_job(&)
        @stream.each(&)
      rescue Busybee::StreamAlreadyClosed
        nil
      end

      # When buffered, join the pump thread and hand back the jobs still buffered.
      # A pump error like NoMemoryError says to exit immediately, so each handback
      # declines and the engine's activation timeout returns those jobs.
      def drain_on_shutdown
        return unless buffer?

        @pump_thread&.join(shutdown_wait_seconds)
        handle_remaining_jobs_in_buffer
      end

      def current_buffer_size = @buffered_job_count&.value
      def peak_buffer_size = @peak_buffer_size&.value

      # Buffer a real job, keeping @buffered_job_count in step with @job_buffer's
      # real jobs. Increment before the push so the gauge never under-reports, and
      # roll back if the push raises, so a failed push can't leak phantom depth.
      # Increment and decrement, not AtomicFixnum#update, whose block re-runs in a
      # CAS loop under contention and would push twice.
      #
      # Take the high-water from increment's own return value, not a later read:
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

      def run_inline
        each_streamed_job do |job|
          activate_job(job, source: :stream)
          if stopping?
            handle_shutdown_job(job)
            break
          end

          execute_job(job)
        rescue Busybee::Worker::Shutdown => e
          declare_unhealthy(e)
          break
        end

        stop!(reason: ending_reason(otherwise: :gateway_closed)) # a no-op behind a stop already claimed
        raise_exit_error
      rescue Busybee::GRPC::Error => e
        raise if claim_stop(:gateway_error, e)
      end

      # The pump thread's body. The ensure is the backstop unblocking the main
      # thread's blocking pop: a no-op behind any earlier stop!, and reached live
      # only by the gateway closing the stream cleanly (:gateway_closed) or the
      # loop leaving on the fire alarm.
      def pump_stream_into_buffer
        ending_pump_on_error { pump_jobs }
      ensure
        ending_pump_on_error { stop!(reason: ending_reason(otherwise: :gateway_closed)) }
      end

      # Pump the stream into the buffer until stopped. Whatever ends it, whatever
      # its class, goes to end_pump under its discerned reason (Shutdown→:unhealthy,
      # gRPC→:gateway_error, else :crash), ahead of the ensure's default. Clean
      # closes arrive as Cancelled and are absorbed.
      def pump_jobs
        delay = @runtime_config.buffer_throttle

        each_streamed_job do |job|
          break if stopping?

          activate_job(job, source: :stream, buffered: true)
          buffer_job(job)
          sleep(Busybee::Durations.seconds_from(delay)) if delay
        end
      end

      # The pump's thread ends on nothing it raises: a stop announced here runs
      # on_worker_stop_requested on it, so even that hook's error comes to end_pump.
      def ending_pump_on_error
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        end_pump(e, reason_for(e))
      end

      # Whatever ends the pump claims the stop like any other error (see
      # Stopping#claim_stop): the main thread raises a winner as the run's exit
      # error; a loser is a post-stop error. A won claim announces the stop, and
      # what that announcement raises meets a stop already claimed: post-stop.
      def end_pump(error, reason)
        exit_immediately!(reason: reason) unless recoverable?(error) # whether or not its claim wins
        claim_stop(reason, error)
      rescue Exception => e # rubocop:disable Lint/RescueException
        end_pump(e, reason_for(e))
      end

      # Reentrant, so a claim's own record may take it again.
      def synchronize_claim(&) = @stop_lock.synchronize(&)

      # Process jobs from the buffer.
      # blocking: false drains all currently-buffered jobs, returns if/when empty.
      # blocking: true blocks on pop until :stop sentinel or stopping?.
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

      def buffer? = @runtime_config.buffer
      def job_type = @worker_class.configuration.job_type
    end
  end
end

# Direct subclass loads after the class body; it requires this file back.
require "busybee/runner/hybrid"
