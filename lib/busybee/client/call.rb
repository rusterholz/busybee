# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require "busybee/client/call/correlation"
require "busybee/client/call/timestamps"
require "busybee/grpc/error"
require "busybee/hooks"

module Busybee
  class Client
    # Per-logical-call carrier for the call hooks (before_call / around_call /
    # after_call); the block arg is |call|. A plain PORO, not an HWIA event: one
    # per logical client operation, threaded through the seam, accumulating
    # per-attempt outcome and timing behind a read surface computed live.
    # Framework state is written only through the underscore seam methods below —
    # there are no public setters, so the absence of a setter is the seal.
    class Call
      # Errors the seam catches and records. Widening to ScriptError is open.
      RECOVERABLE_ERRORS = [StandardError].freeze

      # Class-level correlation surface (with_job / with_worker_status /
      # current_job / current_worker_status) — see Correlation.
      extend Correlation

      # Wrap a logical client call: build the carrier, fire the gating before_call,
      # run the operation, resolve, fire the observing after_call exactly once.
      # before_call propagates (it can abort the call); after_call swallows.
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

      attr_reader :rpc, :request, :status, :result, :error, :attempts, :job, :worker_status

      def initialize(rpc, request = nil)
        @rpc = rpc
        @request = request
        @status = :pending
        @result = nil
        @error = nil
        @attempts = 0
        @job = self.class.current_job
        @worker_status = self.class.current_worker_status
        @timestamps = Timestamps.new
      end

      # ===== Status predicates =====

      def pending? = status == :pending
      def succeeded? = status == :succeeded
      def errored? = status == :errored
      def resolved? = !pending?

      # ===== Outcome readers =====

      # The recorded error's class and message, or nil.
      def error_class = error&.class
      def error_message = error&.message

      # The gRPC status as a symbol: :ok on success, the recorded error's status
      # when one is present (readable mid-retry), nil otherwise. Synthesized, not
      # delegated, so success reports :ok without a result object to ask.
      def grpc_status
        return :ok if succeeded?
        return error.grpc_status if error.is_a?(Busybee::GRPC::Error)

        nil
      end

      # ===== Timing — the span and per-attempt durations live on Timestamps =====
      delegate :created_at, :resolved_at, :network_started_at, :network_finished_at,
               :network_ms, :backoff_ms, :queue_ms, :total_ms, :cumulative_network_ms,
               to: :@timestamps

      # ===== Projections =====

      # Low-cardinality projection (metric labels): worker + job *correlation*
      # (curated to stable identity, not their lifecycle telemetry) under the
      # call's own tags, which win. Computed live, since status/grpc_status evolve.
      def context_tags
        worker_correlation_tags.merge(job_correlation_tags).merge(own_context_tags).compact
      end

      # High-cardinality projection (logs): a superset adding worker_name, the
      # job/instance keys, and the call's own attempts, durations and message.
      def logging_context
        worker_correlation_logging.merge(job_correlation_logging).merge(own_logging_context).compact
      end

      # ===== Execution seam =====

      # Execute one gRPC attempt inside the observing around_call chain, recording
      # the outcome (gRPC errors translated per attempt) and re-raising any error
      # *past* the chain — the safe chain would otherwise swallow it.
      def attempt
        _begin_attempt
        reopen_request
        Busybee::Hooks.run_chain(:around_call, self, safe: true) do
          @timestamps.begin_network
          begin
            value = yield
            @timestamps.end_network # close the bracket the instant the op settles, before recording
            _record_result(value)
          rescue *RECOVERABLE_ERRORS => e
            @timestamps.end_network
            _record_error(translate_error(e))
          ensure
            @request.freeze # the wire has seen it; from here it is a record, not an input
          end
        end
        # `error` and `result` are the carrier's own attr_readers, set inside the
        # chain core by _record_result / _record_error — not local variables.
        raise error if error

        result
      end

      # ===== Framework-write seam (underscore idiom; no public setters) =====

      # Count an initiated attempt. Called once per around_call entry.
      def _begin_attempt
        @attempts += 1
      end

      # Record this attempt's success. result and error are mutually exclusive,
      # latest-wins, so a retry that succeeds clears the prior attempt's error.
      def _record_result(value)
        @result = value
        @error = nil
      end

      # Record this attempt's error (see _record_result for the contract).
      def _record_error(error)
        @error = error
        @result = nil
      end

      # Set the logical status (:succeeded / :errored) — advances once, at resolution.
      def _resolve(status:)
        @status = status
        @timestamps.stamp_resolved!
      end

      private

      # A retry starts from a writable copy of what the last attempt sent, so
      # every around_call gets the request the first one got. It has to be a wire
      # round-trip: protobuf's dup and clone both hand back a *frozen* copy, and
      # the FrozenError that follows is swallowed by the chain, not raised.
      def reopen_request
        return if attempts < 2 || request.nil?

        @request = request.class.decode(request.class.encode(request))
      end

      # error_class returns the Class; project its name so tags/logs stay scalar.
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

      # What a call log wants from its worker: identity, not lifetime gauges.
      # worker_name is logging-only (per-run-unique); worker_class supplies
      # job_type on a job-less fetch call, where no Job is in scope.
      def worker_correlation_tags
        return {} unless worker_status

        { worker_class: worker_status.worker_class&.name,
          job_type: worker_status.job_type,
          worker_mode: worker_status.worker_mode }
      end

      def worker_correlation_logging
        return {} unless worker_status

        worker_correlation_tags.merge(worker_name: worker_status.worker_name)
      end

      # Correlation identity, not lifecycle timing. retries is excluded: it reads
      # like this call's attempts but means the engine's retry budget for the job.
      def job_correlation_tags
        return {} unless job

        { bpmn_process_id: job.bpmn_process_id, source: job.source }
      end

      def job_correlation_logging
        return {} unless job

        job_correlation_tags.merge(job_key: job.key,
                                   process_instance_key: job.process_instance_key,
                                   element_id: job.element_id)
      end

      # Wrap a raw gRPC error as Busybee::GRPC::Error (keeping it as the cause),
      # per attempt, so error and grpc_status read uniformly across retries.
      def translate_error(error)
        error.is_a?(::GRPC::BadStatus) ? Busybee::GRPC::Error.wrap(error) : error
      end
    end
  end
end
