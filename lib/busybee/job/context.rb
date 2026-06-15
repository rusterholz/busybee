# frozen_string_literal: true

require "date"

module Busybee
  class Job
    # Arbitrary key/value scratch for cross-hook state — the catch-all into
    # which any Job#set_context keys not claimed by Activation or Resolution
    # land. Hook authors use this to pass info between hooks (e.g. a tracing
    # span started in before_job and finished in after_job).
    #
    # Contributes nothing to Job#context_tags (the framework reserves that
    # surface for keys it knows are low-cardinality). Contributes to
    # Job#logging_context, filtered to primitive-valued entries — complex
    # objects in scratch (Hash, Array, custom classes) are dropped from logs;
    # if hook authors need them surfaced, they can extract loggable parts in
    # middleware before passing to their logger directly.
    class Context
      # DateTime is covered transitively (it inherits from Date). ActiveSupport::
      # TimeWithZone is covered transitively too: AS overrides TimeWithZone#is_a?
      # to return true for Time. Both transitive cases are pinned in specs.
      LOGGABLE_PRIMITIVES = [
        String, Symbol, Numeric,
        TrueClass, FalseClass, NilClass,
        Time, Date
      ].freeze

      def initialize
        @data = {}
      end

      def [](key)
        @data[key]
      end

      def []=(key, value)
        @data[key] = value
      end

      def to_h
        @data.dup
      end

      def absorb(kwargs)
        @data.merge!(kwargs)
      end

      def context_tags
        {}
      end

      def logging_context
        @data.select { |_key, value| loggable_primitive?(value) }
      end

      private

      def loggable_primitive?(value)
        LOGGABLE_PRIMITIVES.any? { |type| value.is_a?(type) }
      end
    end
  end
end
