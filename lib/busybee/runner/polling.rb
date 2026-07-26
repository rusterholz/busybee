# frozen_string_literal: true

require "busybee/client/call"
require "busybee/grpc/error"
require "busybee/runner"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # Polling runner — fetches jobs via client.with_each_job in a loop.
    # Each iteration long-polls the gateway for available jobs, yields them
    # sequentially to the worker's perform_job, and handles shutdown/errors.
    class Polling < Runner
      # Fills Runner#run!'s loop: long-poll for jobs and process them until
      # stopped. Gateway backpressure backs off and retries. A per-job Shutdown
      # is stashed in @shutdown_error and re-raised once the loop exits, so the
      # drain runs before it propagates. Single-threaded, so a plain ivar suffices
      # (Streaming's cross-thread pump needs an AtomicReference; polling doesn't).
      def run_loop
        @shutdown_error = nil

        loop do
          break if stopping?

          process_all_available_jobs
        rescue Busybee::GRPC::Error => e
          handle_grpc_error(e) # back off + retry on backpressure, else re-raise
        end

        raise @shutdown_error if @shutdown_error
      end

      private

      def process_all_available_jobs
        # Attribute this cycle's long-poll fetch to the worker: a fresh snapshot
        # (current counters) so a starved worker still reports health via its poll.
        Client::Call.with_worker_status(worker_status) do
          @client.with_each_job(job_type, **@runtime_config.polling_options) do |job|
            activate_job(job, source: :poll)
            if stopping?
              handle_shutdown_job(job)
            else
              execute_job(job)
            end
          rescue Busybee::Worker::Shutdown => e
            @shutdown_error = e
            stop!(reason: :unhealthy) # the worker declared itself down
          end
        end
      end

      def job_type
        @worker_class.configuration.job_type
      end
    end
  end
end
