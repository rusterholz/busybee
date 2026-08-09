# frozen_string_literal: true

require "active_support/duration"

require "busybee/logging"

module Busybee
  # The one home for interpreting duration-ish input. Every surface that takes
  # "a duration" — client operation arguments, gem-level config setters, the
  # worker DSL, keepalive — reads it through here, so the accepted shapes are
  # uniform: Integer milliseconds, an ActiveSupport::Duration, or a numeric
  # String; a stray Numeric is truncated with a warning.
  module Durations
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
      def validate!(name, value)
        return value if value.is_a?(Integer) || value.is_a?(ActiveSupport::Duration)
        return validated_string(name, value) if value.is_a?(String)

        if value.is_a?(Numeric)
          Logging.warn("#{name}: coercing #{value.class} #{value.inspect} to Integer #{value.to_i}")
          return value.to_i
        end

        raise ArgumentError,
              "#{name} accepts Integer, ActiveSupport::Duration, or numeric String, got #{value.class}"
      end

      private

      def validated_string(name, value)
        return value.to_f.to_i if value.match?(/\A\d+(\.\d+)?\z/)

        raise ArgumentError,
              "#{name} accepts Integer, ActiveSupport::Duration, or numeric String, " \
              "got non-numeric String #{value.inspect}"
      end
    end
  end
end
