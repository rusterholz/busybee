# frozen_string_literal: true

require "busybee/hooks/timing"

module Busybee
  class Client
    class Call
      # Timing for a single logical client call: the logical span (created at
      # before_call, resolved at after_call) plus a per-attempt network window
      # that is overwritten each attempt and summed into a cumulative total.
      # Monotonic stamps drive the math; UTC stamps are exposed for logging;
      # durations are rounded to ms only at read. Held privately by Call.
      class Timestamps
        include Busybee::Hooks::Timing

        # Public moments. The first-attempt-start and prior-attempt-finish
        # markers behind queue_ms/backoff_ms are intentionally NOT declared:
        # they have no reader, just carried-forward ivars elapsed_ms can read.
        timestamp :created_at, :resolved_at, :network_started_at, :network_finished_at

        def initialize
          @cumulative_network_monotonic = 0.0
          stamp!(:created_at)
        end

        # This attempt's on-wire time (finished - started); nil until end-of-attempt.
        def network_ms
          elapsed_ms(:network_started_at, :network_finished_at)
        end

        # The real inter-retry gap (this attempt's network start minus the prior
        # attempt's network finish); nil on the first attempt.
        def backoff_ms
          elapsed_ms(:last_attempt_finished_at, :network_started_at)
        end

        # Scheduling latency from construction to the first attempt's network start.
        def queue_ms
          elapsed_ms(:created_at, :first_attempt_started_at)
        end

        # Total logical wall time from construction to resolution; nil until resolved.
        def total_ms
          elapsed_ms(:created_at, :resolved_at)
        end

        # Cumulative on-wire time summed across all attempts. Not a gap between
        # two moments, so it owns its own accumulator and arithmetic.
        def cumulative_network_ms
          (@cumulative_network_monotonic * 1000).round(1)
        end

        # Open this attempt's network window (proceed entry, before the stub
        # call). Carries the prior attempt's finish forward as the backoff basis
        # before overwriting the window, and records the first attempt's start
        # for queue_ms.
        def begin_network
          carry_forward(:last_attempt_finished_at, from: :network_finished_at)
          stamp!(:network_started_at)
          carry_forward(:first_attempt_started_at, from: :network_started_at) unless first_attempt_started?
        end

        # Close this attempt's network window (proceed exit) and add it to the
        # cumulative on-wire total.
        def end_network
          stamp!(:network_finished_at)
          @cumulative_network_monotonic +=
            network_finished_at(:monotonic) - network_started_at(:monotonic)
        end

        # Stamp the logical resolution moment.
        def stamp_resolved!
          stamp!(:resolved_at)
        end

        private

        # Preserve a moment's pair under a marker name before the next attempt
        # overwrites it. The marker has no reader; elapsed_ms reads its ivars.
        def carry_forward(marker, from:)
          instance_variable_set(:"@#{marker}_monotonic", instance_variable_get(:"@#{from}_monotonic"))
          instance_variable_set(:"@#{marker}_utc", instance_variable_get(:"@#{from}_utc"))
        end

        def first_attempt_started?
          !@first_attempt_started_at_monotonic.nil?
        end
      end
    end
  end
end
