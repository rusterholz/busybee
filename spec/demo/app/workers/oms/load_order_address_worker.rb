# frozen_string_literal: true

module Oms
  class LoadOrderAddressWorker < Busybee::Worker
    description "Loads an order's delivery coordinates for distance calculation"

    variable :order_id, type: :uuid, description: "Order to look up"

    output :lat, type: :decimal, description: "Delivery latitude"
    output :lon, type: :decimal, description: "Delivery longitude"

    def perform
      order = Order.find(order_id)
      Rails.logger.info("Loaded delivery address for Order ##{order.short_id}: (#{order.lat}, #{order.lon})")

      { lat: order.lat.to_f, lon: order.lon.to_f }
    end
  end
end
