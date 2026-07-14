# frozen_string_literal: true

class CreateMonitoringEngineCalls < ActiveRecord::Migration[7.0]
  def change
    create_table :monitoring_engine_calls, id: false do |t|
      t.string :id, null: false, primary_key: true
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
