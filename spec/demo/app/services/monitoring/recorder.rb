# frozen_string_literal: true

module Monitoring
  # Records each job's lifecycle into Monitoring::JobRun for the operational
  # dashboard — the demo's stand-in for an observability sink (Datadog, etc.).
  # Wired as busybee on_job_activated / on_job_executed hooks.
  #
  # The runner fires those hooks with safe: true, so anything raised here can
  # never disrupt job execution. On top of that we retry transient SQLite write
  # contention a few times, because the demo's worker containers share one
  # database file.
  module Recorder
    MAX_ATTEMPTS = 3
    RETRY_BACKOFF = 0.02 # seconds, scaled by attempt

    class << self
      def record_activation(job)
        upsert(job) do |run|
          run.activated_at ||= job.activated_at
          run.source = job.source&.to_s
          run.buffer_size = job.buffer_size
        end
      end

      def record_execution(job)
        upsert(job) do |run|
          run.executed_at = job.executed_at
          run.total_duration_ms = job.total_duration_ms
          run.perform_duration_ms = job.perform_duration_ms
          run.execution_duration_ms = job.execution_duration_ms
          run.buffer_latency_ms = job.buffer_latency_ms
          run.error_message = job.error_message
          run.error_code = job.error_code
        end
      end

      private

      def upsert(job)
        with_retries do
          run = JobRun.find_or_initialize_by(job_key: job.key)
          run.job_type = job.job_type
          run.bpmn_process_id = job.bpmn_process_id
          run.status = job.status.to_s
          run.tags = job.context_tags
          yield run
          run.save!
        end
      end

      def with_retries
        attempts = 0
        begin
          attempts += 1
          yield
        rescue ActiveRecord::StatementInvalid => e
          raise if attempts >= MAX_ATTEMPTS || !transient_lock?(e)

          sleep(RETRY_BACKOFF * attempts)
          retry
        end
      end

      def transient_lock?(error)
        error.message.match?(/lock|busy/i)
      end
    end
  end
end
