# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
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
      attr_reader :rpc, :status, :result, :error, :attempts, :context

      def initialize(rpc)
        @rpc = rpc
        @status = :pending
        @result = nil
        @error = nil
        @attempts = 0
        @cumulative_network_mono = 0.0
        @context = Busybee::Hooks.context.with_indifferent_access
        @created_at_mono, @created_at_utc = now_pair
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

      # The recorded error's class name, or nil.
      def error_class
        error&.class&.name
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

      # ===== Timing =====
      #
      # Public readers expose the UTC stamps (for logging); durations are
      # computed from the paired monotonic stamps, rounded to ms at read.

      # Logical start (construction / before_call) and end (resolution).
      def created_at
        @created_at_utc
      end

      def resolved_at
        @resolved_at_utc
      end

      # The current attempt's network window (overwritten each attempt).
      def network_started_at
        @network_started_at_utc
      end

      def network_finished_at
        @network_finished_at_utc
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

      # Scheduling latency from construction to the first attempt's network start
      # (~0 when synchronous; meaningful once calls dispatch to a pool).
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

      # ===== Framework-write seam (underscore idiom; no public setters) =====

      # Count an initiated attempt. Called once per around_call entry.
      def _begin_attempt
        @attempts += 1
      end

      # Open this attempt's network window (proceed entry, just before the stub
      # call). Snapshots the prior attempt's finish as the backoff basis before
      # overwriting it, and records the first attempt's start for queue_ms.
      def _begin_network
        @last_attempt_finished_at_mono = @network_finished_at_mono
        @network_started_at_mono, @network_started_at_utc = now_pair
        @first_attempt_started_at_mono ||= @network_started_at_mono # rubocop:disable Naming/MemoizedInstanceVariableName
      end

      # Close this attempt's network window (proceed exit, just after the stub
      # call) and add it to the cumulative on-wire total.
      def _end_network
        @network_finished_at_mono, @network_finished_at_utc = now_pair
        @cumulative_network_mono += @network_finished_at_mono - @network_started_at_mono
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

      def own_context_tags
        { rpc: rpc, status: status, grpc_status: grpc_status, error_class: error_class }
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
    end
  end
end
