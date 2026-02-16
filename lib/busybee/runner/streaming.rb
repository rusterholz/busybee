# frozen_string_literal: true

module Busybee
  class Runner
    # Streaming runner — receives jobs via client.open_job_stream.
    # The stream continuously pushes newly-activated jobs from the gateway.
    # Note: streams only receive jobs created after the stream opens;
    # pre-existing jobs require polling to retrieve.
    class Streaming < Runner
      def initialize(worker_class, client: nil)
        super(client: client)
        @worker_class = worker_class
      end

      def run!
        @running.make_true
        # [hook: runner.started]
        shutdown_error = nil

        @stream = @client.open_job_stream(job_type, **streaming_options)

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
      ensure
        # [hook: runner.stopping]
        @stream&.close
        @running.make_false
      end

      def stop!
        super
        @stream&.close # unblocks stream.each via GRPC::Cancelled
      end

      private

      def job_type
        @worker_class.configuration.job_type
      end

      def streaming_options
        @worker_class.configuration.streaming_options
      end
    end
  end
end
