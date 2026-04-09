# frozen_string_literal: true

module Busybee
  module Hooks
    # Base mixin for hook event objects. Provides shared convenience methods
    # (error_message, compute_ms) used by all noun-specific event access modules.
    #
    # Noun-specific modules (JobEventAccess, WorkerEventAccess, CallEventAccess)
    # include this module and add their own predicates, durations, and tags.
    module EventAccess
      def error_message
        self[:error_message] || self[:error]&.message
      end

      private

      def compute_ms(from_key, to_key)
        from = self[from_key]
        to = self[to_key]
        return nil unless from && to

        ((to - from) * 1000).round(1)
      end
    end
  end
end
