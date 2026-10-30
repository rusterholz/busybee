# frozen_string_literal: true

module Busybee
  module Testing
    class << self
      # Accept foreign jobs inside the block, as `busybee_foreign_jobs: :accept` does (see ForeignJobs).
      def accepting_foreign_jobs(&) = with_foreign_jobs(:accept, &)

      def accepting_foreign_jobs? = @foreign_jobs == :accept

      # Runs the block in :refuse (the default) or :accept mode; backs the
      # `busybee_foreign_jobs:` metadata.
      #
      # @raise [ArgumentError] on an unknown mode
      def with_foreign_jobs(mode)
        unless ForeignJobs::MODES.include?(mode)
          raise ArgumentError, "Unknown busybee_foreign_jobs mode #{mode.inspect}. Expected :refuse or :accept"
        end

        outer = @foreign_jobs
        begin
          @foreign_jobs = mode
          yield
        ensure
          @foreign_jobs = outer
        end
      end
    end

    # Which activated jobs a workflow test refuses, given the with_process_instance
    # blocks it is inside (outermost first). Refusing, the default: any job of an
    # instance other than the innermost block's. Accepting: only jobs of the
    # enclosing blocks' instances, so a call activity's child or an instance the
    # example started by message can be worked. Outside every block: none.
    class ForeignJobs
      MODES = %i[refuse accept].freeze

      def initialize(instances, accepting:)
        @instances = instances.dup.freeze
        @accepting = accepting
      end

      def current = @instances.last

      def foreign?(job)
        return false unless current

        @accepting ? @instances[0...-1].include?(job.processInstanceKey) : job.processInstanceKey != current
      end

      def hand_back_message(job)
        "Handed back unworked by a busybee workflow test: the job belongs to process " \
          "instance #{job.processInstanceKey}, not the test's process instance #{current}"
      end

      # @param refused [Array] raw jobs handed back, one per job key
      def no_job_message(type, refused)
        message = "No job of type '#{type}' available"
        return message if refused.empty?

        owners = refused.map(&:processInstanceKey).uniq
        jobs = refused.size == 1 ? "1 job" : "#{refused.size} jobs"
        "#{message} for process instance #{current}. Handed back unworked: #{jobs} " +
          (@accepting ? from_enclosing(refused.size, owners) : from_others(owners))
      end

      private

      def from_enclosing(jobs, owners)
        whose = owners.one? ? "an enclosing with_process_instance block's" : "enclosing with_process_instance blocks'"
        "of #{whose} #{owners.one? ? 'process instance' : 'process instances'} (#{owners.join(', ')}), " \
          "which can take #{jobs == 1 ? 'it' : 'them'} once " \
          "#{owners.one? ? 'that block resumes' : 'those blocks resume'}"
      end

      def from_others(owners)
        "of #{owners.one? ? 'another process instance' : 'other process instances'} (#{owners.join(', ')}). " \
          "To accept jobs of instances the example didn't start itself, such as a call activity's, " \
          "tag it busybee_foreign_jobs: :accept"
      end
    end
  end
end
