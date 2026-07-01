# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/module/delegation"
require "busybee/client/call/timestamps"
require "busybee/grpc/error"
require "busybee/hooks"

module Busybee
  class Client
    # Per-logical-call carrier for the call hooks (before_call / around_call /
    # after_call); the block arg is |call|. A plain PORO, not an HWIA event:
    # one Call is constructed per logical client operation and threaded through
    # the hook seam, accumulating per-attempt outcome and timing and exposing a
    # read surface (predicates, durations, grpc_status, context tags) computed
    # live at read time.
    #
    # Framework state is written only through the underscore seam methods
    # (_begin_attempt / _record_result / _record_error / _resolve); there are no
    # public setters, so the absence of a setter is the seal.
    class Call
      # Errors the seam catches and records. StandardError today; widening to
      # also include ScriptError is tracked as a future mission.
      RECOVERABLE_ERRORS = [StandardError].freeze

      # Wrap a logical client call: construct the carrier, fire the gating
      # before_call, run the operation (which records its per-attempt outcome onto
      # the carrier), resolve, and fire the observing after_call exactly once.
      # before_call propagates (so it can abort the call); after_call observes
      # (swallows). Returns the recorded result on success; re-raises on error.
      def self.with_hooks(rpc, request = nil)
        call = new(rpc, request)
        Busybee::Hooks.run(:before_call, call)
        begin
          yield(call)
          call._resolve(status: :succeeded)
          call.result
        rescue *RECOVERABLE_ERRORS
          call._resolve(status: :errored)
          raise
        ensure
          Busybee::Hooks.run(:after_call, call, safe: true) if call.resolved?
        end
      end

      attr_reader :rpc, :request, :status, :result, :error, :attempts, :context

      def initialize(rpc, request = nil)
        @rpc = rpc
        @request = request
        @status = :pending
        @result = nil
        @error = nil
        @attempts = 0
        @context = Busybee::Hooks.context.with_indifferent_access
        @timestamps = Timestamps.new
      end

      # ===== Status predicates =====

      def pending?
        status == :pending
      end

      def succeeded?
        status == :succeeded
      end

      def errored?
        status == :errored
      end

      def resolved?
        !pending?
      end

      # ===== Outcome readers =====

      # The recorded error's class, or nil. Returns the Class (like worker_class),
      # so a hook filter matches it by Class, name string, or Regexp uniformly; the
      # tag/log projections coerce it to its name for scalar labels.
      def error_class
        error&.class
      end

      # The recorded error's message, or nil.
      def error_message
        error&.message
      end

      # The gRPC status as a symbol: :ok on success; the recorded gRPC error's
      # status when one is present (readable mid-retry, before resolution); nil
      # otherwise. Synthesized rather than delegated, so a successful call reports
      # :ok (gRPC's success code) without a result object to ask.
      def grpc_status
        return :ok if succeeded?
        return error.grpc_status if error.is_a?(Busybee::GRPC::Error)

        nil
      end

      # ===== Timing (delegated to Timestamps) =====
      #
      # The logical span and per-attempt network durations live on Timestamps;
      # its read surface is exposed directly on the call.
      delegate :created_at, :resolved_at, :network_started_at, :network_finished_at,
               :network_ms, :backoff_ms, :queue_ms, :total_ms, :cumulative_network_ms,
               to: :@timestamps

      # ===== Context =====

      # Annotate the context bag from a hook. Set-once per key: seeded keys and
      # prior annotations are never clobbered. For deliberate updates, mutate a
      # mutable value stored under a fixed key.
      def set_context(**kwargs)
        kwargs.each { |key, value| @context[key] = value unless @context.key?(key) }
        self
      end

      # Low-cardinality projection (metric labels): the call's own tags reverse-
      # merged over any context value's context_tags, so the call's own keys win.
      # Computed live, since status/grpc_status/durations evolve over the call.
      def context_tags
        context_contributions(:context_tags).merge(own_context_tags).compact
      end

      # High-cardinality projection (logs): a superset of context_tags adding
      # attempts, durations, and error_message, reverse-merged the same way.
      def logging_context
        context_contributions(:logging_context).merge(own_logging_context).compact
      end

      # ===== Execution seam =====

      # Execute one gRPC attempt inside the observing around_call chain. Records
      # the outcome onto the carrier (translating gRPC errors per attempt), then
      # re-raises any error *past* the chain: around_call is observing (the safe
      # chain swallows raises), so the error is recorded, not raised through it.
      def attempt
        _begin_attempt
        Busybee::Hooks.run_chain(:around_call, self, safe: true) do
          @timestamps.begin_network
          begin
            _record_result(yield)
          rescue *RECOVERABLE_ERRORS => e
            _record_error(translate_error(e))
          ensure
            @timestamps.end_network
          end
        end
        # `error` and `result` are the carrier's own readers (attr_reader), set
        # just above by _record_result / _record_error inside the chain core —
        # they are not local variables.
        raise error if error

        result
      end

      # ===== Framework-write seam (underscore idiom; no public setters) =====

      # Count an initiated attempt. Called once per around_call entry.
      def _begin_attempt
        @attempts += 1
      end

      # Record this attempt's success result. result and error are mutually
      # exclusive, latest-wins: recording one clears the other, so after the final
      # attempt exactly one is live and is the logical outcome (a retry that
      # succeeds clears the prior attempt's error).
      def _record_result(value)
        @result = value
        @error = nil
      end

      # Record this attempt's error (see _record_result for the latest-wins
      # mutual-exclusion contract).
      def _record_error(error)
        @error = error
        @result = nil
      end

      # Set the logical status (:succeeded / :errored) — advances once, at final
      # resolution.
      def _resolve(status:)
        @status = status
        @timestamps.stamp_resolved!
      end

      private

      # error_class returns the Class; project its name so tags/logs stay scalar
      # labels (own_logging_context builds on this, inheriting the coercion).
      def own_context_tags
        { rpc: rpc, status: status, grpc_status: grpc_status, error_class: error_class&.name }
      end

      def own_logging_context
        own_context_tags.merge(
          attempts: attempts,
          total_ms: total_ms,
          network_ms: network_ms,
          backoff_ms: backoff_ms,
          error_message: error_message
        )
      end

      # Merge the context_tags/logging_context of any context value implementing
      # the duck protocol. The value owns its own cardinality split (e.g. a Job
      # puts job_type in tags, job_key in logging).
      def context_contributions(method_name)
        @context.each_value.with_object({}) do |value, contributions|
          contributions.merge!(value.public_send(method_name)) if value.respond_to?(method_name)
        end
      end

      # Translate a raw gRPC error to a Busybee::GRPC::Error (preserving it as the
      # cause); pass any non-gRPC error through unchanged. Per attempt, so the
      # recorded error and grpc_status read uniformly across retries.
      def translate_error(error)
        error.is_a?(::GRPC::BadStatus) ? Busybee::GRPC::Error.wrap(error) : error
      end
    end
  end
end
