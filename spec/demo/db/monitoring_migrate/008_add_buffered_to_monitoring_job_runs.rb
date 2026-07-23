# frozen_string_literal: true

class AddBufferedToMonitoringJobRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :monitoring_job_runs, :buffered, :boolean
  end
end
