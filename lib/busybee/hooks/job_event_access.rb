# frozen_string_literal: true

require "busybee/hooks/event_access"

module Busybee
  module Hooks
    # Job-specific event access mixin. Provides status predicates, computed
    # durations for the 6-timestamp job lifecycle, and low-cardinality tags.
    module JobEventAccess
      include EventAccess

      TAG_KEYS = %i[job_type worker_class status bpmn_process_id].freeze

      def completed?
        self[:status] == :complete
      end

      def failed?
        self[:status] == :failed
      end

      def error?
        self[:status] == :error
      end

      alias errored? error?

      def perform_duration_ms
        compute_ms(:perform_started_at, :perform_finished_at)
      end

      def resolution_duration_ms
        compute_ms(:execution_started_at, :resolved_at)
      end

      def execution_duration_ms
        compute_ms(:execution_started_at, :executed_at)
      end

      def buffer_latency_ms
        compute_ms(:activated_at, :execution_started_at)
      end

      def total_duration_ms
        compute_ms(:activated_at, :resolved_at)
      end

      def post_resolution_ms
        compute_ms(:resolved_at, :executed_at)
      end

      def setup_duration_ms
        compute_ms(:execution_started_at, :perform_started_at)
      end

      def tags
        TAG_KEYS.each_with_object({}) do |key, hash|
          value = self[key]
          hash[key.to_s] = value unless value.nil?
        end
      end
    end
  end
end
