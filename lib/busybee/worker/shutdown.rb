# frozen_string_literal: true

require "busybee/error"

module Busybee
  class Worker
    # Raised when a `shutdown_on` exception is caught during perform_job.
    # Signals to the Runner that the worker process should shut down.
    # The original exception is available via `cause` (set by Ruby at raise time).
    class Shutdown < Busybee::Error
      attr_reader :worker_class

      def initialize(message = "Shutting down worker #{Busybee.worker_name}", worker_class:)
        @worker_class = worker_class
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

      # Whether an error is one the worker (or the gem config) declared fatal —
      # the shutdown_on classification, shared by the worker's perform rescue
      # and the hook layer's safe-run rescue. worker_class may be nil or
      # configuration-less (a bare hook target); only gem-level classes apply then.
      def self.triggered_by?(error, worker_class)
        per_worker = worker_class.respond_to?(:configuration) ? worker_class.configuration.shutdown_on : []
        (per_worker + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
      end
    end
  end
end
