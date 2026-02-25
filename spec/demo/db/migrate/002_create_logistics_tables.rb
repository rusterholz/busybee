# frozen_string_literal: true

class CreateLogisticsTables < ActiveRecord::Migration[7.0]
  def change # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :logistics_warehouses, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :name, null: false
      t.string :address_line_1
      t.string :city
      t.string :state
      t.string :zip
      t.decimal :lat, precision: 5, scale: 1, null: false
      t.decimal :lon, precision: 5, scale: 1, null: false
    end

    create_table :logistics_stock_items, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :warehouse_id, null: false
      t.string :item_type, null: false
      t.integer :quantity, null: false, default: 0
    end

    add_index :logistics_stock_items, :warehouse_id
    add_index :logistics_stock_items, %i[warehouse_id item_type], unique: true

    create_table :logistics_shipments, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :order_id, null: false
      t.string :warehouse_id, null: false
      t.string :status, null: false, default: "pending"
      t.json :items
      t.bigint :deliver_shipment_instance_key
      t.timestamps
    end

    add_index :logistics_shipments, :order_id
    add_index :logistics_shipments, :warehouse_id
  end
end
