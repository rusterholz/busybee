# frozen_string_literal: true

module Monitoring
  # One row per job activation (a re-offered job keeps its key, so the time is
  # part of it), on a hypertable. Written by Monitoring::Recorder's job hooks.
  class JobRun < Record
    self.table_name = "monitoring_job_runs"
    self.primary_key = %i[job_key activated_at]

    skip_callback :create, :before, :assign_uuid

    OUTCOMES = %w[complete failed error handed_back].freeze
    RESOLVED = %w[complete failed error].freeze # the runs a failure rate and a timing are taken over

    scope :recent, -> { order(activated_at: :desc) }
    scope :within, ->(window) { where(activated_at: window.from..window.to) }
    scope :resolved, -> { where(status: RESOLVED) }

    class << self
      def percentile_sql(fraction, column = :total_duration_ms) = super

      # Percent of resolved runs with a status, as a SELECT expression.
      def share_sql(status)
        "100.0 * COUNT(*) FILTER (WHERE status = #{connection.quote(status)}) / " \
          "NULLIF(COUNT(*) FILTER (WHERE status IN ('complete', 'failed', 'error')), 0)"
      end
    end
  end
end
