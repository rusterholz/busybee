# frozen_string_literal: true

require "busybee/error"

module Busybee
  class Worker
    # The worker process should shut down — raised by `shutdown_on`, or by
    # usercode declaring unhealth itself. `cause` carries the original, if any.
    class Shutdown < Busybee::Error
      attr_reader :worker_class

      # worker_class is optional so `raise Shutdown, "msg"` can be written at all.
      def initialize(message = "Shutting down worker #{Busybee.worker_name}", worker_class: nil)
        @worker_class = worker_class
        super(message)
      end

      # Conditional: naming an absent cause gives "replica lag too high due to error".
      def message
        super.dup.tap do |msg|
          msg << " due to #{cause.class.name || 'error'}" if cause
          msg << " in #{worker_class.name}" if worker_class&.name
          msg << ": \"#{cause.message}\"" if cause
        end
      end

      # The triggering error: a Shutdown's cause (or itself, uncaused); anything
      # else passes through. The one unwrap exit classification and autofail read.
      def self.unwrap(exception)
        return exception unless exception.is_a?(self)

        exception.cause || exception
      end

      # The shutdown_on classification, shared by the perform and hook rescues.
      # A nil or configuration-less worker_class leaves only the gem-level list.
      def self.triggered_by?(error, worker_class)
        per_worker = worker_class.respond_to?(:configuration) ? worker_class.configuration.shutdown_on : []
        (per_worker + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
      end
    end
  end
end
