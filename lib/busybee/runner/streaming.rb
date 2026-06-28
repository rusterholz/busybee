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
        @shutdown_error = Concurrent::AtomicReference.new(nil)
      end

      def stop!
        super
        @stream&.close # unblocks stream.each via GRPC::Cancelled
        @job_buffer&.push(:stop) if buffer?
      end

      def kill!
        super
        @pump_thread&.kill
        return unless buffer?

        @job_buffer.clear
        @job_buffer.push(:stop)
      end

      private

      # Fills Runner#run!'s loop: open the job stream and process jobs (via the
      # pump + buffer, or inline). Raises a worker Shutdown to signal an error exit.
      def run_loop
        @stream = @client.open_job_stream(job_type, job_timeout: @runtime_config.job_timeout)

        if buffer?
          run_with_buffer
        else
          run_inline
        end
      end

      # Close the job stream so no new jobs are activated. Backstop for the
      # error-exit path; stop! already closes it on the graceful path.
      def cease_intake
        @stream&.close
      end

      # When buffered, join the pump thread and fail any jobs still in the buffer.
      def drain_on_shutdown
        return unless buffer?

        @pump_thread&.join(5)
        handle_remaining_jobs_in_buffer
      end

      def current_buffer_size
        return nil if @job_buffer.nil?

        # Discount the :stop sentinel that stop! pushes into the buffer so
        # the depth reported during shutdown reflects only real jobs.
        @job_buffer.size - (stopping? ? 1 : 0)
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
          @job_buffer.push(job)
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
