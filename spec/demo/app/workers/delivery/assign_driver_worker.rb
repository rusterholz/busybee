# frozen_string_literal: true

module Delivery
  class AssignDriverWorker < Busybee::Worker
    description "Assigns the available driver with the lowest total mileage to a shipment"

    variable :shipment_id, type: :uuid, description: "Shipment to assign a driver to"

    output :driver_id,   type: :uuid,   description: "Assigned driver's ID"
    output :driver_name, type: :string, description: "Assigned driver's name"

    def perform
      driver = Driver.transaction do
        Driver.available.by_mileage.first!.tap do |d|
          d.update!(current_shipment_id: shipment_id)
        end
      end

      Rails.logger.info("Assigned Driver #{driver.name} to Shipment ##{short_shipment_id}")
      { driver_id: driver.id, driver_name: driver.name }
    end

    private

    def short_shipment_id
      hex = shipment_id.delete("-").last(5).upcase
      "#{hex[0..2]}-#{hex[3..4]}"
    end
  end
end
