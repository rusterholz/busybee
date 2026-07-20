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

      # The triggering error behind a shutdown: for a Shutdown, its wrapped cause
      # (or the Shutdown itself when raised without one); any other exception —
      # nil included — passes through unchanged. The single unwrap the runner's
      # exit classification and the worker's autofail both read.
      def self.unwrap(exception)
        return exception unless exception.is_a?(self)

        exception.cause || exception
      end
    end
  end
end
