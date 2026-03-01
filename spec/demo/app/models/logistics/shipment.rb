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

    after_commit :start_deliver_shipment, on: :update

    def item_count
      (items || []).sum { |i| i["qty"] || 1 }
    end

    def as_json(*)
      {
        id: id,
        order_id: order_id,
        item_count: item_count,
        warehouse: warehouse.as_json.except(:name)
      }
    end

    private

    # In a real distributed system, process instances would be kicked off by an asynchronous
    # event-driven mechanism. For this demo app, we use ActiveRecord callbacks + service classes:

    def start_deliver_shipment
      return unless saved_change_to_status? && status == "packed"

      Logistics::StartDeliverShipment.call(self)
    end
  end
end
