# frozen_string_literal: true

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

      # Thread-local keys for the call-correlation carriers (see .with_job /
      # .with_worker_status).
      JOB_KEY = :_busybee_call_job
      WORKER_STATUS_KEY = :_busybee_call_worker_status

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

      # ===== Correlation context (class-level) =====
      #
      # The executing Job and the runner's Worker::Status are seeded on the thread
      # so a Call built mid-operation attributes itself (see #initialize). Windows
      # are single-carrier — a job window (worker's perform_job) or a worker window
      # (the runner's fetch/lifecycle windows) — so each carrier has its own
      # seeder/reader. Each is restored to its prior value on block exit.

      def self.with_job(job)
        previous = Thread.current[JOB_KEY]
        Thread.current[JOB_KEY] = job
        yield
      ensure
        Thread.current[JOB_KEY] = previous
      end

      def self.with_worker_status(worker_status)
        previous = Thread.current[WORKER_STATUS_KEY]
        Thread.current[WORKER_STATUS_KEY] = worker_status
        yield
      ensure
        Thread.current[WORKER_STATUS_KEY] = previous
      end

      def self.current_job
        Thread.current[JOB_KEY]
      end

      # Fall-through safety: a present job's own status wins over any separately-
      # seeded one, so a Call's job and worker_status can never disagree.
      def self.current_worker_status
        job = current_job
        job ? job.worker_status : Thread.current[WORKER_STATUS_KEY]
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

      # ===== Projections =====

      # Low-cardinality projection (metric labels): worker + job *correlation*
      # (curated to stable identity, not their lifecycle telemetry) under the
      # call's own tags, which win. Computed live, since status/grpc_status evolve.
      def context_tags
        worker_correlation_tags.merge(job_correlation_tags).merge(own_context_tags).compact
      end

      # High-cardinality projection (logs): a superset adding the worker/job keys
      # a call log wants (worker_name, job/instance keys) plus the call's own
      # attempts, durations, and error message.
      def logging_context
        worker_correlation_logging.merge(job_correlation_logging).merge(own_logging_context).compact
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
            value = yield
            @timestamps.end_network # close the bracket the instant the op settles, before recording
            _record_result(value)
          rescue *RECOVERABLE_ERRORS => e
            @timestamps.end_network
            _record_error(translate_error(e))
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

      # What a call log wants from its worker: identity, not lifetime gauges.
      # worker_name is logging-only — it can be per-run-unique (high-cardinality
      # as a metric label). worker_class is the source of job_type on a job-less
      # fetch call, where no Job is in scope.
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

      # What a call log wants from its job: correlation identity, not lifecycle
      # timing/result. retries is deliberately excluded — it reads like this call's
      # attempts but means the engine's retry budget for the job.
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

      # Translate a raw gRPC error to a Busybee::GRPC::Error (preserving it as the
      # cause); pass any non-gRPC error through unchanged. Per attempt, so the
      # recorded error and grpc_status read uniformly across retries.
      def translate_error(error)
        error.is_a?(::GRPC::BadStatus) ? Busybee::GRPC::Error.wrap(error) : error
      end
    end
  end
end
