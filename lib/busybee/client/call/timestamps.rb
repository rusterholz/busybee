# frozen_string_literal: true

module Busybee
  class Client
    class Call
      # Timing for a single logical client call: the logical span (created at
      # before_call, resolved at after_call) plus a per-attempt network window
      # that is overwritten each attempt and summed into a cumulative total.
      # Monotonic stamps drive the math; UTC stamps are exposed for logging;
      # durations are rounded to ms only at read. Held privately by Call.
      class Timestamps
        def initialize
          @cumulative_network_mono = 0.0
          @created_at_mono, @created_at_utc = now_pair
        end

        # Logical span. Readers take a kind arg (:utc default, for logging;
        # :monotonic for math) — the same API as Job::Timestamps.
        def created_at(type = :utc)
          read_pair(@created_at_utc, @created_at_mono, type)
        end

        def resolved_at(type = :utc)
          read_pair(@resolved_at_utc, @resolved_at_mono, type)
        end

        # Current attempt's network window (overwritten each attempt).
        def network_started_at(type = :utc)
          read_pair(@network_started_at_utc, @network_started_at_mono, type)
        end

        def network_finished_at(type = :utc)
          read_pair(@network_finished_at_utc, @network_finished_at_mono, type)
        end

        # This attempt's on-wire time (finished - started); nil until end-of-attempt.
        def network_ms
          ms_between(@network_started_at_mono, @network_finished_at_mono)
        end

        # The real inter-retry gap (this attempt's network start minus the prior
        # attempt's network finish); nil on the first attempt.
        def backoff_ms
          ms_between(@last_attempt_finished_at_mono, @network_started_at_mono)
        end

        # Scheduling latency from construction to the first attempt's network start.
        def queue_ms
          ms_between(@created_at_mono, @first_attempt_started_at_mono)
        end

        # Total logical wall time from construction to resolution; nil until resolved.
        def total_ms
          ms_between(@created_at_mono, @resolved_at_mono)
        end

        # Cumulative on-wire time summed across all attempts.
        def cumulative_network_ms
          (@cumulative_network_mono * 1000).round(1)
        end

        # Open this attempt's network window (proceed entry, before the stub call).
        # Snapshots the prior attempt's finish as the backoff basis before
        # overwriting it, and records the first attempt's start for queue_ms.
        def begin_network
          @last_attempt_finished_at_mono = @network_finished_at_mono
          @network_started_at_mono, @network_started_at_utc = now_pair
          @first_attempt_started_at_mono ||= @network_started_at_mono # rubocop:disable Naming/MemoizedInstanceVariableName
        end

        # Close this attempt's network window (proceed exit) and add it to the
        # cumulative on-wire total.
        def end_network
          @network_finished_at_mono, @network_finished_at_utc = now_pair
          @cumulative_network_mono += @network_finished_at_mono - @network_started_at_mono
        end

        # Stamp the logical resolution moment.
        def stamp_resolved!
          @resolved_at_mono, @resolved_at_utc = now_pair
        end

        private

        def now_pair
          [Process.clock_gettime(Process::CLOCK_MONOTONIC), Time.now.utc]
        end

        def ms_between(from, to)
          return nil unless from && to

          ((to - from) * 1000).round(1)
        end

        # Select the UTC or monotonic stamp of a pair; mirrors Job::Timestamps'
        # kind arg.
        def read_pair(utc, monotonic, type)
          case type
          when :utc then utc
          when :monotonic then monotonic
          else raise ArgumentError, "Unknown timestamp type: #{type.inspect}. Expected :utc or :monotonic."
          end
        end
      end
    end
  end
end
