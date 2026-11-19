# frozen_string_literal: true

require "busybee/error"
require "busybee/logging"

module Busybee
  class Job
    # A job's view of its process instance's business ID (Camunda 8.10+): the
    # one the job arrived with, and one staged to ride back with its completion,
    # dropped once the job fails or errors instead. Zeebe rejects any business
    # ID once an instance has one, the identical one too, so staging refuses
    # whenever the job arrived with one, nil included.
    class BusinessId
      MAX_LENGTH = 256

      def initialize(job)
        @job = job
      end

      def arrived = @job.payload.process_instance_business_id
      def staged = (@staged unless @job.failed? || @job.error?)
      def current = staged || arrived

      # @raise [Busybee::BusinessIdAlreadyAssigned] if the job arrived with one
      # @raise [ArgumentError] if value is empty or longer than MAX_LENGTH
      def stage(value)
        ensure_unassigned!
        value = validated(value)
        warn_restaged(value)
        @staged = value
      end

      # The complete_job kwargs: none unless staged.
      def completion_kwargs = { business_id: staged }.compact

      private

      def ensure_unassigned!
        return unless arrived

        raise Busybee::BusinessIdAlreadyAssigned, "Cannot assign a business ID to process instance " \
                                                  "#{@job.process_instance_key}, it already has #{arrived.inspect}"
      end

      # Mirrors Zeebe's own checks, as the completion that would fail them comes
      # later. Zeebe counts length in UTF-16 code units.
      def validated(value)
        return if value.nil?

        value = value.to_s
        raise ArgumentError, "business ID can't be empty" if value.empty?
        if value.encode(Encoding::UTF_16LE).bytesize > MAX_LENGTH * 2
          raise ArgumentError, "business ID is longer than #{MAX_LENGTH} characters"
        end

        value
      end

      def warn_restaged(value)
        return unless staged && value && value != staged

        Logging.warn("Replacing staged business ID #{staged.inspect} with #{value.inspect} " \
                     "on #{@job.type} job ##{@job.key}", @job)
      end
    end
  end
end
