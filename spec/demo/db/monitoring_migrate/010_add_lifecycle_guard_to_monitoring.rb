# frozen_string_literal: true

class AddLifecycleGuardToMonitoring < ActiveRecord::Migration[7.0]
  def change
    %i[monitoring_job_runs monitoring_worker_processes].each do |table|
      add_column table, :lifecycle_rank, :integer
      add_column table, :seen_at, :float
    end
  end
end
