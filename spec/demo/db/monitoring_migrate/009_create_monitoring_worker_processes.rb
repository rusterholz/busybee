# frozen_string_literal: true

class CreateMonitoringWorkerProcesses < ActiveRecord::Migration[7.0]
  def change
    create_table :monitoring_worker_processes, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :worker_name, null: false
      t.string :job_type, null: false
      t.string :worker_class
      t.string :worker_mode
      t.string :status
      t.string :reason
      t.string :error_class
      t.string :error_message
      t.integer :total_job_count
      t.integer :failed_job_count
      t.integer :backpressure_count
      t.integer :current_buffer_size
      t.integer :peak_buffer_size
      t.datetime :started_at
      t.datetime :stop_requested_at
      t.datetime :stopping_at
      t.datetime :shutdown_at

      t.timestamps
    end

    add_index :monitoring_worker_processes, %i[worker_name job_type], unique: true
    add_index :monitoring_worker_processes, :job_type
    add_index :monitoring_worker_processes, :status
  end
end
