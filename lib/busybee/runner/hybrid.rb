# frozen_string_literal: true

require "busybee/client/call"
require "busybee/grpc/error"
require "busybee/runner/streaming"
require "busybee/worker/shutdown"

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

      # Inserts the drain phase between pump start and buffer processing. On the
      # main thread, sequentially: drain the backlog by polling until caught up,
      # then process from the buffer only until the stream is canceled.
      def run_with_buffer
        @pump_thread = Thread.new { pump_stream_into_buffer }
        drain_backlog_while_also_processing_buffer
        process_buffered_jobs(blocking: true)
        raise_exit_error
      end

      def drain_options
        @drain_options ||= @runtime_config.polling_options.merge(request_timeout: -1)
      end

      # Each drain poll is attributed to the worker, as Polling's are. After each
      # polled job, stream jobs that arrived meanwhile go first: keeping up with
      # the stream outranks working through the backlog.
      def drain_backlog_while_also_processing_buffer # rubocop:disable Metrics/AbcSize
        loop do
          break if stopping?

          polled_count = Client::Call.with_worker_status(worker_status) do
            @client.with_each_job(job_type, **drain_options) do |job|
              activate_job(job, source: :poll)
              if stopping?
                handle_shutdown_job(job)
              else
                execute_job(job)
                process_buffered_jobs(blocking: false)
              end
            rescue Busybee::Worker::Shutdown => e
              declare_unhealthy(e)
            end
          end

          break if polled_count < drain_options[:max_jobs] # Caught up: fewer than requested
        rescue Busybee::GRPC::Error => e
          handle_grpc_error(e) # back off + retry on backpressure, else re-raise
        end
      end
    end
  end
end
