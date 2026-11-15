# frozen_string_literal: true

class RecordEngineCallsAsAHypertable < ActiveRecord::Migration[7.0]
  def up
    enable_extension "timescaledb"
    drop_table :monitoring_call_metrics
    drop_table :monitoring_engine_calls

    create_table :monitoring_engine_calls, id: false do |t|
      t.timestamptz :at, null: false
      # context_tags: low-cardinality, safe to group or chart by
      t.text :rpc, null: false
      t.text :status
      t.text :grpc_status
      t.text :error_class
      t.text :worker_class
      t.text :job_type
      t.text :worker_mode
      t.text :bpmn_process_id
      t.text :source
      # logging_context: identifiers and measures, for filtering and drilling in
      t.text :worker_name
      t.bigint :job_key
      t.bigint :process_instance_key
      t.text :element_id
      t.integer :attempts
      t.float :network_ms
      t.float :backoff_ms
      t.float :total_ms
      t.text :error_message
      t.float :seq, null: false
    end

    execute "SELECT create_hypertable('monitoring_engine_calls', by_range('at', INTERVAL '1 hour'))"
    add_index :monitoring_engine_calls, %i[job_key at]
    add_index :monitoring_engine_calls, %i[worker_name at]
  end

  def down = raise ActiveRecord::IrreversibleMigration
end
