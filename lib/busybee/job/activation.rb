# frozen_string_literal: true

require "active_support/core_ext/hash/slice"

module Busybee
  class Job
    # Captures the context of how a Job was received and is being executed:
    # `source` (which receive path it came in on), `buffered?` (whether this job
    # came through a runner buffer), and `worker` (the worker instance processing
    # it). `worker_class` is set explicitly at activate time and also derivable
    # from `worker.class` once the instance lands.
    #
    # Populated in two phases: `Runner#activate_job` sets `source`, `buffered`,
    # and `worker_class` at receive time; `Worker.perform_job` sets `worker`
    # once the instance is constructed. Both call sites route
    # through `Job#set_context`, which dispatches to `Activation#harvest!`
    # — extracting any Activation-owned keys from the kwargs hash in place
    # and applying them.
    class Activation
      KEYS = %i[worker worker_class source buffered].freeze
      VALID_SOURCES = %i[poll stream].freeze

      attr_reader :worker, :source

      # worker_class is known at activate_job time (the runner has it) before
      # the worker instance exists (created later in Worker.perform_job). Prefer
      # the explicitly-set value; fall back to deriving from worker.class once
      # the instance lands.
      def worker_class
        @worker_class || @worker&.class
      end

      # Whether this job came through a runner buffer — the irreducible per-job
      # bit ("was THIS job buffered?"). Buffer depth lives on Worker::Status.
      def buffered? = !!@buffered

      def harvest!(kwargs)
        data = kwargs.extract!(*KEYS)
        validate_source!(data[:source]) if data.key?(:source)
        data.each { |key, value| instance_variable_set(:"@#{key}", value) }
      end

      def context_tags
        { source: @source, worker_class: worker_class&.name, buffered: @buffered }.compact
      end

      def logging_context
        context_tags
      end

      private

      def validate_source!(source)
        return if VALID_SOURCES.include?(source)

        raise ArgumentError, "Invalid source: #{source.inspect}. Must be one of #{VALID_SOURCES.inspect}"
      end
    end
  end
end
