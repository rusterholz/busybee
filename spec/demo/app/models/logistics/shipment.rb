# frozen_string_literal: true

# == Schema Information
#
# Table name: logistics_shipments
#
#  id                             :string           not null, primary key
#  order_id                       :string           not null
#  warehouse_id                   :string           not null
#  status                         :string           default("pending"), not null
#  items                          :json
#  deliver_shipment_instance_key  :bigint
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#
# Indexes
#
#  index_logistics_shipments_on_order_id      (order_id)
#  index_logistics_shipments_on_warehouse_id  (warehouse_id)
#

module Logistics
  class Shipment < ApplicationRecord
    self.table_name = "logistics_shipments"

    belongs_to :warehouse, class_name: "Logistics::Warehouse", inverse_of: :shipments

    # order_id is a cross-domain reference — no belongs_to association.

    scope :for_order, ->(order_id) { where(order_id: order_id) }
    scope :by_status, ->(status) { where(status: status) }

    after_commit :on_packed_start_deliver_shipment, on: :update

    private

    def on_packed_start_deliver_shipment
      return unless saved_change_to_status? && status == "packed"

      vars = {
        shipment: {
          id: id,
          order_id: order_id,
          warehouse: {
            id: warehouse_id,
            address: { lat: warehouse.lat.to_f, lon: warehouse.lon.to_f }
          }
        }
      }

      # TODO: Use busybee async mode when available. Production apps need error handling here.
      key = Busybee::Client.new.start_instance("deliver_shipment", vars: vars)
      update_column(:deliver_shipment_instance_key, key)
    end
  end
end
