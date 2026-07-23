# frozen_string_literal: true

class CreateMonitoringCallMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :monitoring_call_metrics, id: false do |t|
      t.string :id, null: false, primary_key: true
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
    add_index :monitoring_call_metrics, :metric_name
  end
end
