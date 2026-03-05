# frozen_string_literal: true

require "busybee/error"

module Busybee
  class Worker
    # Raised when a `shutdown_on` exception is caught during perform_job.
    # Signals to the Runner that the worker process should shut down.
    # The original exception is available via `cause` (set by Ruby at raise time).
    class Shutdown < Busybee::Error
      attr_reader :worker_class

      def initialize(message = "Shutting down worker #{Busybee.worker_name}", worker:)
        @worker_class = worker
        super(message)
      end

      def message
        super.dup.tap do |msg|
          msg << " due to #{cause&.class&.name || 'error'}"
          msg << " in #{worker_class.name}" if worker_class&.name
          msg << ": \"#{cause.message}\"" if cause
        end
      end
    end
  end
end
