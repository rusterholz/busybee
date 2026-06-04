# frozen_string_literal: true

require "active_support/core_ext/hash/slice"

module Busybee
  class Job
    # Tracks the resolution state of a Job: the lifecycle phase
    # (`:ready`, `:complete`, `:failed`, `:error`) and the data captured at
    # resolution — the result hash on `:complete`; some combination of error,
    # error_message, error_code on `:failed`/`:error`.
    #
    # A fresh Resolution starts in `:ready` with no data. Status transitions
    # go through `resolve_to`, which enforces the fire-once invariant.
    # Resolution data is set via `harvest!`, which extracts any of its data
    # keys present in the given kwargs hash (mutating in place). Held
    # privately by Job; relevant readers and predicates are delegated.
    class Resolution
      # Resolution data fields handled by the generic harvest! routing. :result
      # is intentionally NOT here — it has its own set_result setter (set-once
      # + HWIA + freeze) so it can't be silently rewritten via set_context.
      DATA_KEYS = %i[error error_message error_code].freeze

      attr_reader :status, :result, *DATA_KEYS

      def initialize
        @status = :ready
        @result_set = false
      end

      def resolve_to(status)
        raise "Resolution already set to #{@status.inspect}" unless ready?

        @status = status
      end

      # Capture the job's result. Set-once: first Hash-valued call wins;
      # subsequent calls (and non-Hash / nil values) are silent no-ops.
      # Stored as a frozen HashWithIndifferentAccess.
      def set_result(value) # rubocop:disable Naming/AccessorMethodName
        return if @result_set
        return unless value.is_a?(Hash)

        @result = value.with_indifferent_access.freeze
        @result_set = true
      end

      # True when set_result has accepted a Hash value (the result is
      # captured); false before set_result is called and after a rejected
      # non-Hash / nil call. Prefer this over `result.nil?`: future
      # extensions might accept nil as a meaningful "no output" sentinel.
      def result_set?
        @result_set
      end

      def harvest!(kwargs)
        kwargs.extract!(*DATA_KEYS).each { |key, value| instance_variable_set(:"@#{key}", value) }
      end

      def ready?
        status == :ready
      end

      def complete?
        status == :complete
      end
      alias completed? complete?

      def failed?
        status == :failed
      end

      def error?
        status == :error
      end
      alias errored? error?

      def resolved?
        !ready?
      end

      # The human-readable error message: the explicit error_message when set,
      # otherwise the message of the carried exception. Returns nil when both
      # are absent.
      def error_message
        @error_message || @error&.message
      end

      def context_tags
        { status: @status }
      end

      def logging_context
        context_tags.merge(
          result: @result,
          error: @error,
          error_message: @error_message,
          error_code: @error_code
        ).compact
      end
    end
  end
end
