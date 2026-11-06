# frozen_string_literal: true

class CreateMonitoringTables < ActiveRecord::Migration[7.0]
  def change
    create_job_runs
    create_worker_processes
    create_call_metrics
    create_engine_calls
  end

  private

  def create_job_runs
    create_table :monitoring_job_runs, id: :string do |t|
      t.bigint :job_key, null: false
      t.string :job_type, null: false
      t.string :bpmn_process_id
      t.string :status
      t.string :source
      t.integer :buffer_size
      t.boolean :buffered
      t.datetime :activated_at
      t.datetime :executed_at
      t.float :total_duration_ms
      t.float :perform_duration_ms
      t.float :execution_duration_ms
      t.float :buffer_latency_ms
      t.string :error_message
      t.string :error_code
      t.json :tags
      t.integer :lifecycle_rank
      t.float :seen_at
      t.timestamps
    end

    add_index :monitoring_job_runs, :job_key, unique: true
    add_index :monitoring_job_runs, :job_type
    add_index :monitoring_job_runs, :activated_at
  end

  def create_worker_processes
    create_table :monitoring_worker_processes, id: :string do |t|
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
      t.integer :write_queue_depth
      t.datetime :started_at
      t.datetime :stop_requested_at
      t.datetime :stopping_at
      t.datetime :shutdown_at
      t.integer :lifecycle_rank
      t.float :seen_at
      t.timestamps
    end

    add_index :monitoring_worker_processes, %i[worker_name job_type], unique: true
    add_index :monitoring_worker_processes, :job_type
    add_index :monitoring_worker_processes, :status
  end

  def create_call_metrics
    create_table :monitoring_call_metrics, id: :string do |t|
      t.string :metric_name, null: false
      t.string :tag_key, null: false
      t.json :tags
      t.integer :count, null: false, default: 0
      t.float :minimum
      t.float :maximum
      t.float :ewma
      t.float :ewmv
    end

    add_index :monitoring_call_metrics, %i[metric_name tag_key], unique: true
  end

  def create_engine_calls
    create_table :monitoring_engine_calls, id: :string do |t|
      t.bigint :job_key, null: false
      t.string :worker_name
      t.string :rpc, null: false
      t.string :status
      t.float :network_ms
      t.string :error_class
      t.float :seq, null: false
      t.timestamps
    end

    add_index :monitoring_engine_calls, :job_key
    add_index :monitoring_engine_calls, :worker_name
  end
end
