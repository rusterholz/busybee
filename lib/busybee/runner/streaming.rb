# frozen_string_literal: true

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
      def initialize(worker_class, runtime_config: nil, client: nil)
        super
        return unless buffer?

        @job_buffer = Queue.new
        # Real jobs in @job_buffer, tracked apart from Queue#size so the depth
        # gauge ignores the :stop control sentinels the queue also carries.
        @buffered_job_count = Concurrent::AtomicFixnum.new(0)
        @peak_buffer_size = Concurrent::AtomicFixnum.new(0)
        @shutdown_error = Concurrent::AtomicReference.new(nil)
      end

      def kill!
        super
        @pump_thread&.kill
        return unless buffer?

        @job_buffer.clear
        @buffered_job_count.value = 0 # cleared queue holds no real jobs
        @job_buffer.push(:stop)
      end

      private

      # Fills Runner#run!'s loop: open the job stream and process jobs (via the
      # pump + buffer, or inline). Raises a worker Shutdown to signal an error exit.
      def run_loop
        # Attribute the stream-open fetch to the worker. This one snapshot goes
        # stale over the stream's life; execute-time re-seeding keeps the per-job
        # worker current (the stream's own jobs re-seed as they're processed).
        @stream = Client::Call.with_worker_status(worker_status) do
          @client.open_job_stream(job_type, job_timeout: @runtime_config.job_timeout)
        end

        if buffer?
          run_with_buffer
        else
          run_inline
        end
      end

      # Stop new jobs arriving: close the stream (unblocks stream.each via
      # GRPC::Cancelled) and drop the :stop sentinel that unblocks a blocking
      # buffer pop. The single intake-cessation point — base #stop! calls it
      # before firing on_worker_stop_requested (close-before-fire), and the
      # run! ensure calls it again as the backstop for the error-exit path
      # where stop! was never called. Idempotent: a second close is a no-op and
      # extra :stop sentinels are skipped on drain.
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

      # Buffer a real job, keeping @buffered_job_count in step with the real jobs
      # in @job_buffer — the depth/peak gauges read it, and it deliberately
      # excludes the :stop control sentinels the queue also carries. Increment
      # before the push so the gauge never momentarily under-reports; roll the
      # increment back if the push raises, so a failed push can't leak phantom
      # depth. (Deliberately not AtomicFixnum#update: under contention its block
      # re-runs in a CAS loop, which would double-push a side-effecting push.)
      #
      # Record the high-water from increment's own return value, not a later
      # value read — a consumer pop on another thread can decrement between the
      # push and the peak update, so re-reading would miss the depth this push
      # actually reached.
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
          stop!
          break
        end

        raise shutdown_error if shutdown_error
      end

      def pump_stream_into_buffer
        delay = @runtime_config.buffer_throttle

        @stream.each do |job|
          break if stopping?

          activate_job(job, source: :stream, buffered: true)
          buffer_job(job)
          sleep(delay.to_f / 1000) if delay
        end
      rescue StandardError => e
        # Stream error (e.g., GRPC::Error). Store and stop so main thread can re-raise.
        # Normal close via stop! produces GRPC::Cancelled, which JobStream#each absorbs —
        # so this only fires on genuine failures.
        @shutdown_error.update { |prev| prev || e }
      ensure
        # Stream ended — either naturally (external close, server-side close),
        # via error (handled above), or because stop! was already called.
        # In all cases, stop! to unblock the main thread's buffer pop.
        # Idempotent when stop! was already called.
        stop!
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
          @shutdown_error.update { |prev| prev || e }
          stop!
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

      def buffer?
        @runtime_config.buffer
      end

      def job_type
        @worker_class.configuration.job_type
      end
    end
  end
end
