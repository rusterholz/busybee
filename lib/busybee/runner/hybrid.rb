# frozen_string_literal: true

module Busybee
  class Runner
    # Hybrid runner — combines polling and streaming for best-of-both-worlds job processing.
    # Opens a stream first (captures all new jobs), then drains the backlog via polling,
    # then transitions to queue-only processing. A pump thread reads from the stream
    # into a thread-safe Queue; the main thread does all perform_job calls (sequential guarantee).
    # Queue size will be reported through instrumentation hooks in v0.4 to permit monitoring;
    # if you see it rise too large, you need to increase your number of replicas for this job type
    # or configure a larger pump delay, but too large of a pump delay will cause Zeebe to
    # deprioritize this worker.
    class Hybrid < Runner
      BACKPRESSURE_ERRORS = [::GRPC::ResourceExhausted].freeze

      def initialize(worker_class, client: nil)
        super(client: client)
        @worker_class = worker_class
        @job_queue = Queue.new
        @shutdown_error = Concurrent::AtomicReference.new(nil)
      end

      def run!
        return if stopping?

        @running.make_true
        # [hook: runner.started]

        # Phase 1: Open stream (registers with gateway, captures all new jobs)
        @stream = @client.open_job_stream(job_type, **streaming_options)

        # Start pump thread: reads from stream, pushes to queue
        @pump_thread = Thread.new { pump_stream_into_queue }

        # Phase 2: Drain backlog via polling (main thread, sequential)
        drain_backlog_while_also_processing_queue

        # Phase 3: Process from queue only (main thread, sequential)
        process_queued_jobs(blocking: true) # blocks until `stopping?`

        err = @shutdown_error.get
        raise err if err
      ensure
        # [hook: runner.stopping]
        @stream&.close
        @pump_thread&.join(5)
        handle_remaining_jobs_in_queue
        @running.make_false
      end

      def stop!
        super
        @stream&.close
        @job_queue&.push(:stop)
      end

      private

      def pump_stream_into_queue
        @stream.each do |job|
          break if stopping?

          @job_queue.push(job)
        end
      rescue StandardError => e
        # Stream error (e.g., GRPC::Error). Store and stop so main thread can re-raise.
        # Normal close via stop! produces GRPC::Cancelled, which JobStream#each absorbs —
        # so this only fires on genuine failures.
        @shutdown_error.update { |prev| prev || e }
        stop!
      end

      def drain_backlog_while_also_processing_queue
        loop do
          break if stopping?

          polled_count = @client.with_each_job(job_type, **polling_options) do |job|
            if stopping?
              handle_shutdown_job(job)
            else
              @worker_class.perform_job(job)
              # After each polled job, drain any stream jobs that arrived —
              # always prioritize keeping up with the stream over working through backlog.
              process_queued_jobs(blocking: false)
            end
          rescue Busybee::Worker::Shutdown => e
            @shutdown_error.update { |prev| prev || e }
            stop!
          end

          break if polled_count < max_jobs # Caught up: fewer than requested
        rescue *BACKPRESSURE_ERRORS
          # [hook: runner.backpressure]
          sleep Busybee.runner_backpressure_delay
        end
      end

      # Process jobs from the queue.
      # blocking: false — drains all currently-queued jobs, returns if/when empty, used for phase 2.
      # blocking: true  — blocks on pop until :stop sentinel or stopping?, used for phase 3.
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

      def job_type
        @worker_class.configuration.job_type
      end

      def max_jobs
        polling_options[:max_jobs]
      end

      def streaming_options
        @worker_class.configuration.streaming_options
      end

      # For draining, polls always use request_timeout: -1 (immediate return) to avoid long-polling.
      def polling_options
        @worker_class.configuration.polling_options.merge(request_timeout: -1)
      end
    end
  end
end
