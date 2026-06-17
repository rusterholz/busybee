# frozen_string_literal: true

class CreateOmsTables < ActiveRecord::Migration[7.0]
  def change
    create_table :oms_orders, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :customer_name, null: false
      t.string :address_line_1
      t.string :city
      t.string :state
      t.string :zip
      t.decimal :lat, precision: 5, scale: 1, null: false
      t.decimal :lon, precision: 5, scale: 1, null: false
      t.string :status, null: false, default: "submitted"
      t.bigint :prepare_order_instance_key
      t.bigint :ship_order_instance_key
      t.timestamps
    end

    create_table :oms_line_items, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :order_id, null: false
      t.string :item_type, null: false
      t.integer :quantity, null: false, default: 1
    end

    add_index :oms_line_items, :order_id
  end
end
