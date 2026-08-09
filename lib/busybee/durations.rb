# frozen_string_literal: true

require "active_support/duration"

require "busybee/logging"

module Busybee
  # The one home for interpreting duration-ish input. Every surface that takes
  # "a duration" — client operation arguments, gem-level config setters, the
  # worker DSL, keepalive — reads it through here, so the accepted shapes are
  # uniform: a number of milliseconds, an ActiveSupport::Duration, or a numeric
  # String. Values are stored as written — fractions included — and converted
  # once, by whichever consumer needs them.
  module Durations
    # A configured duration below its knob's floor is far likelier to be a units
    # slip — seconds written where milliseconds were meant, always a factor of
    # 1000 — than a deliberate choice, so it earns a warning. Floors sit one to
    # two orders under each default, low enough that aggressive tuning stays
    # quiet. Both spellings of a knob are listed rather than derived, so the
    # table reads as the documentation it is. buffer_throttle is deliberately
    # absent: its sub-millisecond values are a documented rate cap.
    IMPLAUSIBLE_BELOW_MS = {
      default_job_timeout: 1_000,
      job_timeout: 1_000,
      default_polling_request_timeout: 1_000,
      request_timeout: 1_000,
      grpc_keepalive_interval: 1_000,
      grpc_keepalive_timeout: 1_000,
      default_message_ttl: 100,
      default_fail_job_backoff: 100,
      fail_job_backoff: 100,
      default_backpressure_delay: 100,
      backpressure_delay: 100,
      grpc_retry_delay: 50
    }.freeze

    class << self
      # Whole milliseconds from a duration-ish value. Coercive, not validating —
      # for argument surfaces whose defaults have already been applied.
      def milliseconds_from(value)
        value.is_a?(ActiveSupport::Duration) ? value.in_milliseconds.to_i : value.to_i
      end

      # Seconds from a duration-ish value (Integer input read as milliseconds).
      # to_f, not in_seconds — the latter truncates, so 0.25.seconds would arrive
      # as "don't wait at all".
      def seconds_from(value)
        value.is_a?(ActiveSupport::Duration) ? value.to_f : value / 1000.0
      end

      # Validating form for config surfaces: returns the value to assign,
      # raising ArgumentError on shapes outside the contract. A caller with its
      # own error vocabulary (the worker DSL) wraps the raise.
      # Fractions survive here and truncate at the wire instead, in
      # milliseconds_from — which is what lets one contract cover both a job
      # timeout and buffer_throttle's documented sub-millisecond values.
      def validate!(name, value)
        # Duration answers is_a?(Numeric) truthfully enough for this test.
        return warn_if_implausible(name, value) if value.is_a?(Numeric)
        return warn_if_implausible(name, validated_string(name, value)) if value.is_a?(String)

        raise ArgumentError,
              "#{name} accepts a number, ActiveSupport::Duration, or numeric String, got #{value.class}"
      end

      private

      # Zero and negatives are sentinels — "no delay", and -1 for "answer
      # immediately, don't long-poll" — while a units slip always lands
      # small-but-positive. Returns the value either way: this advises, it
      # doesn't reject.
      def warn_if_implausible(name, value)
        floor = IMPLAUSIBLE_BELOW_MS[name]
        return value unless floor

        ms = seconds_from(value) * 1000
        return value unless ms.positive? && ms < floor

        shown = readable(ms)
        Logging.warn("#{name}: #{shown}ms seems unusually small for this setting. Durations here are " \
                     "milliseconds — if you meant #{shown} seconds, use #{readable(ms * 1000)} or #{shown}.seconds")
        value
      end

      # Whole values print as integers; 2000.0ms reads like a rounding artifact.
      def readable(number)
        (number % 1).zero? ? number.to_i : number
      end

      def validated_string(name, value)
        return value.to_i if value.match?(/\A\d+\z/)
        return value.to_f if value.match?(/\A\d+\.\d+\z/)

        raise ArgumentError,
              "#{name} accepts a number, ActiveSupport::Duration, or numeric String, " \
              "got non-numeric String #{value.inspect}"
      end
    end
  end
end
