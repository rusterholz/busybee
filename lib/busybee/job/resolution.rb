# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module Busybee
  class Job
    # Tracks the resolution state of a Job: the lifecycle phase
    # (`:ready`, `:complete`, `:failed`, `:error`) and the outcome data
    # captured at resolution — the result hash on `:complete`; some
    # combination of error, error_message, error_code on `:failed`/`:error`.
    #
    # A fresh Resolution starts in `:ready` with no outcome. Status
    # transitions go through `resolve_to`, which enforces the fire-once
    # invariant. Outcome data is captured on two independent axes:
    # `set_result` (success) and `set_error` (failure / BPMN error). Each
    # axis is set-once on its own — Variant D legitimately ends up with
    # both set (manual fail before perform returns a partial-payload hash).
    #
    # Worth naming a third independent axis: `result` and `error` are
    # worker-side records of what came out of executing the job; `status`
    # is the engine's ledger as reflected on this worker, advancing only
    # after a GRPC resolution call succeeds. The worker never observes
    # engine state directly, so the two ledgers can diverge — `:failed`
    # on the worker can pair with an incident on the engine, and `:ready`
    # on the worker can pair with the engine still seeing the job as
    # ACTIVATED (Zeebe's engine-side name for what Busybee calls `:ready`).
    # Held privately by Job; relevant readers and predicates are delegated.
    class Resolution
      # Error-shaped fields recognized by `set_error` when given a Hash.
      DATA_KEYS = %i[error error_message error_code].freeze

      # The status + outcome-data keys this PORO owns. Reserved at the
      # `Job#set_context` boundary so they can't be silently rewritten as
      # scratch — the warning there steers callers to the dedicated setters
      # (`complete!`, `fail!`, `throw_bpmn_error!`).
      OWNED_KEYS = (%i[status result] + DATA_KEYS).freeze

      attr_reader :status, :result, *DATA_KEYS

      def initialize
        @status = :ready
        @result_set = false
        @error_set = false
      end

      def resolve_to(status)
        raise "Resolution already set to #{@status.inspect}" unless ready?

        @status = status
      end

      # Capture the job's success result. Set-once on the result axis: first
      # Hash-valued call wins. Non-Hash / nil values are silent no-ops.
      # Independent of `set_error` — both axes can land (Variant D).
      # Stored as a frozen HashWithIndifferentAccess.
      def set_result(value) # rubocop:disable Naming/AccessorMethodName
        return if @result_set
        return unless value.is_a?(Hash)

        @result = value.with_indifferent_access.freeze
        @result_set = true
      end

      # Capture the job's error outcome. Set-once on the error axis: first
      # call with a recognized payload wins. Accepts either an Exception
      # (stored as `@error`) or a Hash containing any of `:error`,
      # `:error_message`, `:error_code` (compacted; explicit nils dropped;
      # remaining values stored to the corresponding ivars). Unrecognized
      # inputs and inputs with no non-nil recognized keys are silent no-ops.
      # Independent of `set_result` — both axes can land (Variant D).
      def set_error(error_or_data) # rubocop:disable Naming/AccessorMethodName
        return if @error_set

        data = error_data_from(error_or_data)
        return if data.empty?

        apply_error_data(data)
        @error_set = true
      end

      # True once set_result has accepted a Hash value. Tracks the result
      # axis independently of the error axis; prefer this over `result.nil?`
      # since future extensions might accept nil as a meaningful "no output"
      # sentinel.
      def result_set?
        @result_set
      end

      # True once set_error has captured at least one error-shaped field
      # (Exception, error, error_message, or error_code). Tracks the error
      # axis independently of the result axis.
      def error_set?
        @error_set
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

      private

      def error_data_from(error_or_data)
        case error_or_data
        when Exception then { error: error_or_data }
        when Hash then error_or_data.slice(*DATA_KEYS).compact
        else {}
        end
      end

      def apply_error_data(data)
        @error         = data[:error]         if data.key?(:error)
        @error_message = data[:error_message] if data.key?(:error_message)
        @error_code    = data[:error_code]    if data.key?(:error_code)
      end
    end
  end
end
