# frozen_string_literal: true

module Monitoring
  # One row per job activation, recorded by the busybee lifecycle hooks wired in
  # config/initializers/monitoring.rb. Upserted by job_key: on_job_activated
  # creates the row, on_job_executed completes it with timings and outcome.
  class JobRun < Record
    self.table_name = "monitoring_job_runs"

    scope :recent, -> { order(activated_at: :desc) }
  end
end
