# frozen_string_literal: true

module Monitoring
  # One row per resolved gRPC call, fetch calls included: a TimescaleDB hypertable
  # partitioned on the call's resolution time. Insert-only, with no key and no
  # supersede guard, since a call is a fact rather than a state that gets overtaken.
  #
  # The row is busybee's two-cardinality contract laid out as columns. The call's
  # context_tags (rpc, outcome, worker class, job type, workflow) are the columns
  # a chart may group or series by: few distinct values each. Its logging_context
  # adds identifiers and measures (worker_name, job and instance keys, timings)
  # that are filtered on or aggregated, never grouped by, since a series per
  # job_key is a series per row.
  class EngineCall < Record
    self.table_name = "monitoring_engine_calls"
    self.primary_key = nil

    skip_callback :create, :before, :assign_uuid

    TAGS = %i[rpc status grpc_status error_class worker_class job_type worker_mode bpmn_process_id source].freeze
    MEASURES = %i[worker_name job_key process_instance_key element_id attempts
                  network_ms backoff_ms total_ms error_message].freeze

    # A job's calls in observation order (seq is a per-process monotonic stamp;
    # a job's calls all issue from one worker process, so it orders them true).
    scope :for_job, ->(job_key) { where(job_key: job_key).order(:seq) }

    class << self
      # The row a resolved call becomes, or nil for a call with no observed
      # network time. Read synchronously: the carrier is the caller's.
      def row_for(call, seq:)
        return if call.network_ms.nil?

        tags = call.context_tags.slice(*TAGS).transform_values { |value| scalar(value) }
        { at: call.resolved_at, seq: seq, **tags, **call.logging_context.slice(*MEASURES) }
      end

      def record(call, seq:)
        row = row_for(call, seq: seq)
        insert_all([row]) if row
      end

      private

      def scalar(value) = value.is_a?(Symbol) ? value.to_s : value
    end
  end
end
