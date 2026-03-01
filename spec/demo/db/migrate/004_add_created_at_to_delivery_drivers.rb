# frozen_string_literal: true

class AddCreatedAtToDeliveryDrivers < ActiveRecord::Migration[7.0]
  def change
    add_column :delivery_drivers, :created_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
  end
end
