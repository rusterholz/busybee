# frozen_string_literal: true

require "busybee/hooks/timing"

module Busybee
  class Worker
    # Lifecycle timing for a single worker run. The four runner moments
    # (started → stop_requested → stopping → shutdown) as monotonic + UTC
    # pairs, recorded via stamp!(name). Per-moment readers take a kind arg
    # (:utc default for logging, :monotonic for math). Mirrors Job::Timestamps.
    #
    # The runner holds the live, accumulating instance and stamps it across
    # run!; Worker::Status snapshots a dup of it. Named under Worker (not
    # Runner) so the worker-hook carrier and its timing read as one family.
    class Timestamps
      include Busybee::Hooks::Timing

      timestamp :started_at, :stop_requested_at, :stopping_at, :shutdown_at

      # Graceful-drain time: stopping (T2) → shutdown (T3).
      def stop_duration_ms
        elapsed_ms(:stopping_at, :shutdown_at)
      end

      # Stop-acknowledge latency: stop_requested (T1) → stopping (T2). The
      # SIGTERM→drain delay, meaningful even when the run loop is wedged.
      def stop_latency_ms
        elapsed_ms(:stop_requested_at, :stopping_at)
      end

      # Total run lifetime in seconds: started (T0) → shutdown (T3).
      def lifetime_s
        elapsed_ms(:started_at, :shutdown_at)&.then { |ms| (ms / 1000.0).round(1) }
      end
    end
  end
end
