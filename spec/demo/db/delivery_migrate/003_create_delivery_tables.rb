# frozen_string_literal: true

class CreateDeliveryTables < ActiveRecord::Migration[7.0]
  def change
    create_table :delivery_drivers, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :name, null: false
      t.string :current_shipment_id
      t.decimal :total_mileage, precision: 8, scale: 2, null: false, default: 0.0
    end
  end
end
