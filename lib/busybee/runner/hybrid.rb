# frozen_string_literal: true

module Busybee
  class Runner
    # Hybrid runner — combines polling and streaming for best-of-both-worlds job processing.
    # Subclasses Streaming, adding a drain phase: opens a stream first (captures all new jobs),
    # drains the backlog via polling, then transitions to queue-only processing.
    # The pump thread reads from the stream into a thread-safe Queue; the main thread does
    # all perform_job calls (sequential guarantee).
    class Hybrid < Streaming
      BACKPRESSURE_ERRORS = [::GRPC::ResourceExhausted].freeze

      private

      # Always uses pump thread + queue — the drain phase requires it.
      def queue_enabled?
        true
      end

      # Override to insert drain phase between pump start and queue processing.
      def run_with_queue
        @pump_thread = Thread.new { pump_stream_into_queue }

        # Phase 2: Drain backlog via polling (main thread, sequential, returns when backlog is empty)
        drain_backlog_while_also_processing_queue

        # Phase 3: Process from queue only (main thread, sequential, returns when stream is cancelled)
        process_queued_jobs(blocking: true)

        err = @shutdown_error.get
        raise err if err
      end

      def drain_options
        @drain_options ||= @runtime_config.polling_options.merge(request_timeout: -1)
      end

      def drain_backlog_while_also_processing_queue # rubocop:disable Metrics/AbcSize
        loop do
          break if stopping?

          polled_count = @client.with_each_job(job_type, **drain_options) do |job|
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

          break if polled_count < drain_options[:max_jobs] # Caught up: fewer than requested
        rescue *BACKPRESSURE_ERRORS
          # [hook: runner.backpressure]
          sleep @runtime_config.backpressure_delay
        end
      end
    end
  end
end
