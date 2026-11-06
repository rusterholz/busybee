# frozen_string_literal: true

module Monitoring
  # One row per job activation (a re-offered job keeps its key, so the time is
  # part of it), on a hypertable. Written by Monitoring::Recorder's job hooks.
  class JobRun < Record
    self.table_name = "monitoring_job_runs"
    self.primary_key = %i[job_key activated_at]

    skip_callback :create, :before, :assign_uuid

    scope :recent, -> { order(activated_at: :desc) }
  end
end
