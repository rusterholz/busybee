# frozen_string_literal: true

require "concurrent"

module Monitoring
  # Records busybee lifecycle into the Monitoring models — the demo's stand-in
  # for an observability sink (Datadog, etc.). Job activation/execution feed
  # Monitoring::JobRun; the four worker-lifecycle hooks feed WorkerProcess.
  #
  # Writes offload to a single background thread: each hook snapshots its subject
  # synchronously (a Job mutates as it progresses, so we can't defer reading it)
  # and posts the write. One writer matches SQLite's single-writer model — posts
  # drain FIFO, so a subject's rows land in order. Best-effort: a failed write is
  # logged and dropped, never retried into the hot path.
  module Recorder
    class << self
      def record_activation(job)
        upsert(JobRun, { job_key: job.key },
               job_type: job.job_type,
               bpmn_process_id: job.bpmn_process_id,
               status: job.status.to_s,
               source: job.source&.to_s,
               buffer_size: job.worker_status&.current_buffer_size,
               buffered: job.buffered?,
               activated_at: job.activated_at,
               tags: job.context_tags)
      end

      def record_execution(job)
        upsert(JobRun, { job_key: job.key },
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
               tags: job.context_tags)
      end

      # Upsert a worker's current lifecycle phase, keyed by its container identity
      # (worker_name is unique per boot, so each incarnation is its own row). The
      # phase advances the row: running → stop_requested → stopping → shutdown.
      def record_worker(status, worker)
        # The high-cardinality measurements — counters, buffer gauges, lifecycle
        # timestamps — read uniformly off the status snapshot.
        measurements = %i[total_job_count failed_job_count backpressure_count
                          current_buffer_size peak_buffer_size started_at
                          stop_requested_at stopping_at shutdown_at].
                       index_with { |reader| worker.public_send(reader) }

        upsert(WorkerProcess,
               { worker_name: worker.worker_name, job_type: worker.job_type },
               status: status.to_s,
               worker_class: worker.worker_class.name,
               worker_mode: worker.worker_mode.to_s,
               reason: worker.reason&.to_s,
               error_class: worker.error_class&.name,
               error_message: worker.error_message,
               **measurements)
      end

      # One background thread, unbounded queue: posts never block the runner, and
      # writes serialize (matching SQLite) in the order they were posted.
      def executor
        @executor ||= Concurrent::SingleThreadExecutor.new(fallback_policy: :discard)
      end

      private

      # Find-or-create by identity, then apply attributes, on the writer thread.
      def upsert(model, identity, attributes)
        executor.post do
          Monitoring::Record.connection_pool.with_connection do
            model.find_or_initialize_by(identity).update!(attributes)
          end
        rescue StandardError => e
          Rails.logger.warn("[monitoring] dropped #{model.name} #{identity.values.join('/')}: #{e.message}")
        end
      end
    end
  end
end
