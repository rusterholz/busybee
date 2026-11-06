# frozen_string_literal: true

class RecordJobRunsPerActivationAsAHypertable < ActiveRecord::Migration[7.0]
  def up
    drop_table :monitoring_job_runs

    # A job_key repeats when the engine re-offers a job, so an activation is
    # (job_key, activated_at), which also carries the hypertable's time column.
    create_table :monitoring_job_runs, primary_key: %i[job_key activated_at] do |t|
      t.bigint :job_key, null: false
      t.timestamptz :activated_at, null: false
      t.text :job_type, null: false
      t.text :bpmn_process_id
      t.text :element_id
      t.bigint :process_instance_key
      t.text :worker_name
      t.text :status
      t.text :source
      t.integer :buffer_size
      t.boolean :buffered
      t.timestamptz :executed_at
      t.timestamptz :resolved_at
      t.float :total_duration_ms
      t.float :perform_duration_ms
      t.float :execution_duration_ms
      t.float :buffer_latency_ms
      t.text :error_message
      t.text :error_code
      t.json :tags
      t.integer :lifecycle_rank
      t.float :seen_at
      t.timestamptz :created_at, null: false
      t.timestamptz :updated_at, null: false
    end

    execute "SELECT create_hypertable('monitoring_job_runs', by_range('activated_at', INTERVAL '1 hour'))"
    add_index :monitoring_job_runs, %i[job_type activated_at]
    add_index :monitoring_job_runs, %i[bpmn_process_id activated_at]
    add_index :monitoring_job_runs, %i[process_instance_key activated_at], name: "index_monitoring_job_runs_on_instance"
  end

  def down = raise ActiveRecord::IrreversibleMigration
end
