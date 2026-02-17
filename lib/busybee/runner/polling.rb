# frozen_string_literal: true

module Busybee
  class Runner
    # Polling runner — fetches jobs via client.with_each_job in a loop.
    # Each iteration long-polls the gateway for available jobs, yields them
    # sequentially to the worker's perform_job, and handles shutdown/errors.
    class Polling < Runner
      BACKPRESSURE_ERRORS = [::GRPC::ResourceExhausted].freeze

      def initialize(worker_class, client: nil)
        super(client: client)
        @worker_class = worker_class
      end

      def run!
        return if stopping?

        @running.make_true
        # [hook: runner.started]
        shutdown_error = nil

        loop do
          break if stopping?

          process_all_available_jobs { |e| shutdown_error = e }
        rescue *BACKPRESSURE_ERRORS
          # [hook: runner.backpressure]
          sleep Busybee.runner_backpressure_delay
        end

        raise shutdown_error if shutdown_error
      ensure
        # [hook: runner.stopping]
        @running.make_false
      end

      private

      def process_all_available_jobs
        @client.with_each_job(job_type, **polling_options) do |job|
          if stopping?
            handle_shutdown_job(job)
          else
            @worker_class.perform_job(job)
          end
        rescue Busybee::Worker::Shutdown => e
          # [hook: runner.shutdown]
          yield e
          stop!
        end
      end

      def job_type
        @worker_class.configuration.job_type
      end

      def polling_options
        @worker_class.configuration.polling_options
      end
    end
  end
end
