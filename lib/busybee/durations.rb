# frozen_string_literal: true

require "active_support/duration"

require "busybee/logging"

module Busybee
  # The one reader of duration-ish input, for every surface that takes one: a
  # number of milliseconds, an ActiveSupport::Duration, or a numeric String.
  # Values are stored as written, fractions included, and converted once, by
  # whichever consumer needs them.
  module Durations
    # A duration below its knob's floor is likelier a units slip (seconds written
    # for milliseconds, a factor of 1000) than a choice, so it warns. Floors sit
    # one to two orders under each default; both spellings of a knob are listed,
    # not derived. buffer_throttle's sub-millisecond values are a documented cap.
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
      shutdown_wait_timeout: 1_000,
      grpc_retry_delay: 50
    }.freeze

    class << self
      # Whole milliseconds, coercive rather than validating: defaults already applied.
      def milliseconds_from(value)
        value.is_a?(ActiveSupport::Duration) ? value.in_milliseconds.to_i : value.to_i
      end

      # Seconds, an Integer read as milliseconds. to_f, not in_seconds, which
      # truncates: 0.25.seconds would arrive as "don't wait at all".
      def seconds_from(value)
        value.is_a?(ActiveSupport::Duration) ? value.to_f : value / 1000.0
      end

      # Validating form for config surfaces: the value to assign, or ArgumentError
      # (the worker DSL rewraps it). Fractions survive to truncate at the wire, so
      # one contract covers a job timeout and buffer_throttle's sub-millisecond
      # values. A Duration answers is_a?(Numeric) truthfully enough here.
      def validate!(name, value)
        return warn_if_implausible(name, value) if value.is_a?(Numeric)
        return warn_if_implausible(name, validated_string(name, value)) if value.is_a?(String)

        raise ArgumentError,
              "#{name} accepts a number, ActiveSupport::Duration, or numeric String, got #{value.class}"
      end

      private

      # Advises, never rejects. Zero and negatives are sentinels ("no delay";
      # -1, "answer immediately, don't long-poll"); a units slip lands positive.
      def warn_if_implausible(name, value)
        floor = IMPLAUSIBLE_BELOW_MS[name]
        return value unless floor

        ms = seconds_from(value) * 1000
        return value unless ms.positive? && ms < floor

        shown = readable(ms)
        Logging.warn("#{name}: #{shown}ms seems unusually small for this setting. Durations here are " \
                     "milliseconds; if you meant #{shown} seconds, use #{readable(ms * 1000)} or #{shown}.seconds")
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
