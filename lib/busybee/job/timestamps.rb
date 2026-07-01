# frozen_string_literal: true

require "busybee/hooks/timing"

module Busybee
  class Job
    # Lifecycle timestamps for hook instrumentation. Each timestamp is a
    # monotonic + UTC pair, recorded via stamp!(name). Per-moment readers
    # take a kind arg (:utc or :monotonic; default :utc); logging_context
    # dumps the stamped values via the shared Timing#timestamp_hash.
    # Held privately by Job; per-moment readers are delegated up.
    class Timestamps
      include Busybee::Hooks::Timing

      timestamp :activated_at, :execution_started_at, :perform_started_at,
                :perform_finished_at, :resolved_at, :executed_at

      def context_tags
        {}
      end

      def logging_context
        timestamp_hash
      end

      def perform_duration_ms
        elapsed_ms(:perform_started_at, :perform_finished_at)
      end

      def resolution_duration_ms
        elapsed_ms(:execution_started_at, :resolved_at)
      end

      def execution_duration_ms
        elapsed_ms(:execution_started_at, :executed_at)
      end

      def buffer_latency_ms
        elapsed_ms(:activated_at, :execution_started_at)
      end

      def total_duration_ms
        elapsed_ms(:activated_at, :resolved_at)
      end

      def post_resolution_ms
        elapsed_ms(:resolved_at, :executed_at)
      end

      def setup_duration_ms
        elapsed_ms(:execution_started_at, :perform_started_at)
      end
    end
  end
end
