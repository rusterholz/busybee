# frozen_string_literal: true

require "concurrent"

module Monitoring
  # Records each job's lifecycle into Monitoring::JobRun for the operational
  # dashboard — the demo's stand-in for an observability sink (Datadog, etc.).
  # Wired as busybee on_job_activated / on_job_executed hooks.
  #
  # Writes are offloaded to a single background thread. The hook snapshots the
  # job synchronously (the Job is mutated as it progresses, so we can't defer
  # reading it) and posts the write to a SingleThreadExecutor. That keeps the
  # runner thread free of write latency, and one writer matches SQLite's
  # single-writer model — posts drain in FIFO order, so a job's activation row is
  # always written before its execution update. Recording is best-effort: a
  # failed write is logged and dropped, never retried into the hot path.
  module Recorder
    class << self
      def record_activation(job)
        enqueue(
          job_key: job.key,
          job_type: job.job_type,
          bpmn_process_id: job.bpmn_process_id,
          status: job.status.to_s,
          source: job.source&.to_s,
          buffer_size: job.buffer_size,
          activated_at: job.activated_at,
          tags: job.context_tags
        )
      end

      def record_execution(job)
        enqueue(
          job_key: job.key,
          job_type: job.job_type,
          bpmn_process_id: job.bpmn_process_id,
          status: job.status.to_s,
          executed_at: job.executed_at,
          total_duration_ms: job.total_duration_ms,
          perform_duration_ms: job.perform_duration_ms,
          execution_duration_ms: job.execution_duration_ms,
          buffer_latency_ms: job.buffer_latency_ms,
          error_message: job.error_message,
          error_code: job.error_code,
          tags: job.context_tags
        )
      end

      # One background thread, unbounded queue: posts never block the runner, and
      # writes serialize (matching SQLite) in the order they were posted.
      def executor
        @executor ||= Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)
      end

      private

      def enqueue(attributes)
        executor.post { write(attributes) }
      end

      def write(attributes)
        Monitoring::Record.connection_pool.with_connection do
          run = JobRun.find_or_initialize_by(job_key: attributes[:job_key])
          run.update!(attributes.except(:job_key))
        end
      rescue StandardError => e
        Rails.logger.warn("[monitoring] dropped job run #{attributes[:job_key]}: #{e.message}")
      end
    end
  end
end
