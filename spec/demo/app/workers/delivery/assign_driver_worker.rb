# frozen_string_literal: true

module Delivery
  # Assigns the lowest-mileage available driver to a shipment. Always creates a
  # DriverRequest to track the assignment. When no drivers are available, returns
  # nil driver info — the BPMN process will wait at a message catch event until
  # CompleteDriverDeliveryWorker fulfills the request and publishes a message.
  class AssignDriverWorker < Busybee::Worker
    description "Assigns the available driver with the lowest total mileage to a shipment"

    variable :shipment_id, type: :uuid, description: "Shipment to assign a driver to"

    output :driver_id,   type: :uuid,   description: "Assigned driver's ID (nil if none available)"
    output :driver_name, type: :string, description: "Assigned driver's name (nil if none available)"
    output :request_id,  type: :uuid,   description: "Driver request ID for message correlation"

    def perform
      request = DriverRequest.create!(shipment_id: shipment_id)
      driver = try_assign_driver!(request)

      if driver
        Rails.logger.info("Assigned Driver #{driver.name} to Shipment ##{short_shipment_id}")
      else
        Rails.logger.info("No drivers available for Shipment ##{short_shipment_id}, " \
                          "queued as Request #{request.id[..7]}")
      end

      { driver_id: driver&.id, driver_name: driver&.name, request_id: request.id }
    end

    private

    def try_assign_driver!(request)
      driver = Driver.available.by_mileage.first
      return unless driver

      driver.update!(current_shipment_id: shipment_id)
      request.update!(driver_id: driver.id)
      driver
    end

    def short_shipment_id
      hex = shipment_id.delete("-").last(5).upcase
      "#{hex[0..2]}-#{hex[3..4]}"
    end
  end
end
