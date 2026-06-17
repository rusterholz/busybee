# frozen_string_literal: true

class AddBufferLatencyToMonitoringJobRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :monitoring_job_runs, :buffer_latency_ms, :float
  end
end
