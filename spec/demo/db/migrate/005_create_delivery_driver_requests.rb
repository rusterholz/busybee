# frozen_string_literal: true

class CreateDeliveryDriverRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :delivery_driver_requests, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :shipment_id, null: false
      t.string :driver_id
      t.datetime :requested_at, null: false

      t.timestamps
    end

    add_index :delivery_driver_requests, :driver_id
    add_index :delivery_driver_requests, %i[driver_id requested_at],
              where: "driver_id IS NULL", name: "index_delivery_driver_requests_open"
  end
end
