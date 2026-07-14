# frozen_string_literal: true

module Monitoring
  # One row per resolved gRPC call made *during a job's perform* — the high-card
  # (logging_context) projection of the call stream, the log/trace twin of the
  # low-card CallMetric aggregate (context_tags). The same calls, two views: what
  # the two-cardinality contract looks like on the Call noun.
  #
  # Only job-correlated calls are recorded. A call carries a job_key only inside
  # perform; fetch/poll calls have no Job in scope and stay aggregate-only in
  # CallMetric — which is what keeps this table bounded to ~calls-per-job rather
  # than the unbounded long-poll stream.
  class EngineCall < Record
    self.table_name = "monitoring_engine_calls"

    # A job's calls in observation order (seq is a per-process monotonic stamp;
    # a job's calls all issue from one worker process, so it orders them true).
    scope :for_job, ->(job_key) { where(job_key: job_key).order(:seq) }

    # Persist a resolved call from its logging_context. No-op for a call with no
    # job in scope (fetch/poll) or no observed network time. Insert-only — no
    # supersede guard: an EngineCall is a fact, not a state that gets overtaken.
    def self.record(call, seq:)
      ctx = call.logging_context
      return if ctx[:job_key].nil? || ctx[:network_ms].nil?

      create!(job_key: ctx[:job_key], worker_name: ctx[:worker_name], rpc: ctx[:rpc],
              status: ctx[:status]&.to_s, network_ms: ctx[:network_ms],
              error_class: ctx[:error_class], seq: seq)
    end
  end
end
