# frozen_string_literal: true

module Logistics
  class MarkShipmentDeliveredWorker < Busybee::Worker
    description "Marks a shipment as delivered and checks whether all order shipments are complete"

    variable :shipment_id, type: :uuid, description: "Shipment to mark as delivered"
    variable :order_id,    type: :uuid, description: "Order to check for full delivery"

    output :all_delivered, type: :boolean, description: "True when every shipment for the order is now delivered"

    def perform
      all_done = Shipment.transaction do
        Shipment.find(shipment_id).update!(status: "delivered")
        Shipment.for_order(order_id).all? { |s| s.status == "delivered" }
      end

      { all_delivered: all_done }
    end
  end
end
