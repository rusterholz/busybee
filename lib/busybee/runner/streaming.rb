# frozen_string_literal: true

module Busybee
  class Runner
    # Streaming runner — receives jobs via client.open_job_stream.
    # The stream continuously pushes newly-activated jobs from the gateway.
    # Note: streams only receive jobs created after the stream opens;
    # pre-existing jobs require polling to retrieve.
    #
    # Two modes:
    # - queue: true (default) — A pump thread reads from the stream into a Queue;
    #   the main thread pops and processes sequentially. Better shutdown responsiveness
    #   and enables pump delay configuration.
    # - queue: false — stream.each calls perform_job inline on the main thread.
    #   Simpler model for workers that don't need queue features.
    class Streaming < Runner
      def initialize(worker_class, runtime_config: nil, client: nil)
        super
        return unless queue_enabled?

        @job_queue = Queue.new
        @shutdown_error = Concurrent::AtomicReference.new(nil)
      end

      def run!
        return if stopping?

        @running.make_true
        # [hook: runner.started]

        @stream = @client.open_job_stream(job_type, job_timeout: @runtime_config.job_timeout)

        if queue_enabled?
          run_with_queue
        else
          run_inline
        end
      ensure
        # [hook: runner.stopping]
        @stream&.close
        if queue_enabled?
          @pump_thread&.join(5)
          handle_remaining_jobs_in_queue
        end
        @running.make_false
      end

      def stop!
        super
        @stream&.close # unblocks stream.each via GRPC::Cancelled
        @job_queue&.push(:stop) if queue_enabled?
      end

      def kill!
        super
        @pump_thread&.kill
        return unless queue_enabled?

        @job_queue.clear
        @job_queue.push(:stop)
      end

      private

      def run_with_queue
        @pump_thread = Thread.new { pump_stream_into_queue }
        process_queued_jobs(blocking: true)

        err = @shutdown_error.get
        raise err if err
      end

      def run_inline
        shutdown_error = nil

        @stream.each do |job|
          if stopping?
            handle_shutdown_job(job)
            break
          end

          @worker_class.perform_job(job)
        rescue Busybee::Worker::Shutdown => e
          # [hook: runner.shutdown]
          shutdown_error = e
          stop!
          break
        end

        raise shutdown_error if shutdown_error
      end

      def pump_stream_into_queue
        delay = @runtime_config.queue_throttle

        @stream.each do |job|
          break if stopping?

          @job_queue.push(job)
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
        # In all cases, stop! to unblock the main thread's queue pop.
        # Idempotent when stop! was already called.
        stop!
      end

      # Process jobs from the queue.
      # blocking: false — drains all currently-queued jobs, returns if/when empty.
      # blocking: true  — blocks on pop until :stop sentinel or stopping?.
      def process_queued_jobs(blocking:)
        loop do
          break if stopping?

          job = @job_queue.pop(!blocking)
          break if job == :stop

          if stopping?
            handle_shutdown_job(job)
          else
            @worker_class.perform_job(job)
          end
        rescue ThreadError
          break # queue empty (non-blocking only)
        rescue Busybee::Worker::Shutdown => e
          @shutdown_error.update { |prev| prev || e }
          stop!
        end
      end

      # Drain remaining queue during shutdown, failing all jobs.
      def handle_remaining_jobs_in_queue
        loop do
          job = @job_queue.pop(true) # non-blocking
          next if job == :stop

          handle_shutdown_job(job)
        rescue ThreadError
          break # queue empty
        end
      end

      def queue_enabled?
        @runtime_config.queue_enabled
      end

      def job_type
        @worker_class.configuration.job_type
      end
    end
  end
end
