# frozen_string_literal: true

class CreateMonitoringJobRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :monitoring_job_runs, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.bigint :job_key, null: false
      t.string :job_type, null: false
      t.string :bpmn_process_id
      t.string :status
      t.string :source
      t.integer :buffer_size
      t.datetime :activated_at
      t.datetime :executed_at
      t.float :total_duration_ms
      t.float :perform_duration_ms
      t.float :execution_duration_ms
      t.string :error_message
      t.string :error_code
      t.json :tags

      t.timestamps
    end

    add_index :monitoring_job_runs, :job_key, unique: true
    add_index :monitoring_job_runs, :job_type
    add_index :monitoring_job_runs, :activated_at
  end
end
