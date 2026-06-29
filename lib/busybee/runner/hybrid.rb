# frozen_string_literal: true

module Busybee
  class Runner
    # Hybrid runner — combines polling and streaming for best-of-both-worlds job processing.
    # Subclasses Streaming, adding a drain phase: opens a stream first (captures all new jobs),
    # drains the backlog via polling, then transitions to buffer-only processing.
    # The pump thread reads from the stream into a thread-safe buffer; the main thread does
    # all perform_job calls (sequential guarantee).
    class Hybrid < Streaming
      private

      # Always uses pump thread + buffer — the drain phase requires it.
      def buffer?
        true
      end

      # Override to insert drain phase between pump start and buffer processing.
      def run_with_buffer
        @pump_thread = Thread.new { pump_stream_into_buffer }

        # Phase 2: Drain backlog via polling (main thread, sequential, returns when backlog is empty)
        drain_backlog_while_also_processing_buffer

        # Phase 3: Process from buffer only (main thread, sequential, returns when stream is cancelled)
        process_buffered_jobs(blocking: true)

        err = @shutdown_error.get
        raise err if err
      end

      def drain_options
        @drain_options ||= @runtime_config.polling_options.merge(request_timeout: -1)
      end

      def drain_backlog_while_also_processing_buffer # rubocop:disable Metrics/AbcSize
        loop do
          break if stopping?

          polled_count = @client.with_each_job(job_type, **drain_options) do |job|
            activate_job(job, source: :poll)
            if stopping?
              handle_shutdown_job(job)
            else
              execute_job(job)
              # After each polled job, drain any stream jobs that arrived —
              # always prioritize keeping up with the stream over working through backlog.
              process_buffered_jobs(blocking: false)
            end
          rescue Busybee::Worker::Shutdown => e
            @shutdown_error.update { |prev| prev || e }
            stop!
          end

          break if polled_count < drain_options[:max_jobs] # Caught up: fewer than requested
        rescue Busybee::GRPC::Error => e
          handle_grpc_error(e) # back off + retry on backpressure, else re-raise
        end
      end
    end
  end
end
