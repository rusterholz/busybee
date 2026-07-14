# frozen_string_literal: true

class AddWriteQueueDepthToMonitoringWorkerProcesses < ActiveRecord::Migration[7.0]
  def change
    add_column :monitoring_worker_processes, :write_queue_depth, :integer
  end
end
