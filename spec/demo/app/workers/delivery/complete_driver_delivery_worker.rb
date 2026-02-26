# frozen_string_literal: true

module Delivery
  class CompleteDriverDeliveryWorker < Busybee::Worker
    description "Records delivery completion: adds mileage and releases the driver"

    variable :driver_id,   type: :uuid,    description: "Driver who completed the delivery"
    variable :shipment_id, type: :uuid,    description: "Shipment that was delivered"
    variable :distance,    type: :decimal, description: "Distance traveled for this delivery"

    def perform
      Driver.transaction do
        Driver.find(driver_id).then do |driver|
          driver.update!(
            total_mileage: driver.total_mileage + BigDecimal(distance.to_s),
            current_shipment_id: nil
          )
        end
      end
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
