# frozen_string_literal: true

module Logistics
  class MarkShipmentInTransitWorker < Busybee::Worker
    description "Marks a shipment as in-transit and checks whether this is the first shipment en route"

    variable :shipment_id, type: :uuid, description: "Shipment to mark as in transit"
    variable :order_id,    type: :uuid, description: "Order to check for first in-transit shipment"

    output :first_in_transit, type: :boolean, description: "True when this is the first shipment en route"

    def perform
      shipment = Shipment.find(shipment_id)
      first = Shipment.transaction do
        shipment.update!(status: "in_transit")
        Shipment.for_order(order_id).where(status: "in_transit").one?
      end
      Rails.logger.info("Shipment ##{shipment.short_id} marked as in transit (first_in_transit=#{first})")

      { first_in_transit: first }
    end
  end
end
