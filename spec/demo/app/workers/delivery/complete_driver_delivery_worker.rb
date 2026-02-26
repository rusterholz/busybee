# frozen_string_literal: true

module Delivery
  class CompleteDriverDeliveryWorker < Busybee::Worker
    description "Records delivery completion: adds mileage and releases the driver"

    variable :driver_id,   type: :uuid,    description: "Driver who completed the delivery"
    variable :shipment_id, type: :uuid,    description: "Shipment that was delivered"
    variable :distance,    type: :decimal, description: "Distance traveled for this delivery"

    def perform
      driver = Driver.find(driver_id)
      new_mileage = driver.total_mileage + BigDecimal(distance.to_s)
      driver.update!(total_mileage: new_mileage, current_shipment_id: nil)
      shipment = Logistics::Shipment.find(shipment_id)
      msg = "Driver #{driver.name} completed Shipment ##{shipment.short_id} " \
            "(+#{distance} miles, total: #{new_mileage.round(1)})"
      Rails.logger.info(msg)
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
