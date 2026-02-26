# frozen_string_literal: true

module Logistics
  class LoadOrderShipmentsWorker < Busybee::Worker
    description "Loads all shipments for an order with item counts"

    variable :order_id, type: :uuid, description: "Order to load shipments for"

    output :shipments, description: "Array of {id, item_count} for the order's shipments"

    def perform
      result = shipments
      Rails.logger.info("Loaded #{result.size} shipment(s) for Order #{order_id[..7]}")
      { shipments: result }
    end

    private

    def shipments
      Shipment.
        for_order(order_id).
        includes(:warehouse).
        map { |s| s.as_json.slice(:id, :item_count) }
    end
  end
end
