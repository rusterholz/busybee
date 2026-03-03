# frozen_string_literal: true

module Delivery
  # After a delivery, releases the driver and checks for queued requests. If a
  # shipment is waiting for a driver, this worker claims the oldest open request,
  # assigns the driver, and publishes a BPMN message to unblock the waiting
  # process instance.
  #
  # Idempotent on retry: if the driver was already released (current_shipment_id
  # != the job's shipment_id), skips mileage and release. If a request was
  # already claimed by this driver, re-publishes the message.
  class CompleteDriverDeliveryWorker < Busybee::Worker
    description "Records delivery completion: adds mileage and releases the driver"

    variable :driver_id,   type: :uuid,    description: "Driver who completed the delivery"
    variable :shipment_id, type: :uuid,    description: "Shipment that was delivered"
    variable :distance,    type: :decimal, description: "Distance traveled for this delivery"

    def perform
      driver = Driver.find(driver_id)
      release_driver!(driver) if driver.current_shipment_id == shipment_id

      fulfill_request!(driver)
    end

    private

    def release_driver!(driver)
      new_mileage = driver.total_mileage + BigDecimal(distance.to_s)
      driver.update!(total_mileage: new_mileage, current_shipment_id: nil)

      Rails.logger.info("Driver #{driver.name} completed Shipment ##{short_shipment_id} " \
                        "(+#{distance} miles, total: #{new_mileage.round(1)})")
    end

    def fulfill_request!(driver)
      request = claim_or_find_request!(driver)
      return unless request

      publish_driver_available!(request, driver)
    end

    def claim_or_find_request!(driver)
      # State C (retry): driver already assigned to a claimed request
      already_claimed = DriverRequest.find_by(driver_id: driver.id, shipment_id: driver.current_shipment_id)
      return already_claimed if already_claimed

      # Normal path: claim the oldest open request
      DriverRequest.transaction do
        request = DriverRequest.open.lock.first
        return unless request

        request.update!(driver_id: driver.id)
        driver.update!(current_shipment_id: request.shipment_id)
        request
      end
    end

    def publish_driver_available!(request, driver)
      # TODO: busybee v0.4 — expose client publicly so workers can publish messages
      zeebe_client = job.instance_variable_get(:@client)
      zeebe_client.publish_message(
        "driver_available",
        correlation_key: request.id,
        vars: { driver_id: driver.id, driver_name: driver.name },
        ttl: 30.seconds
      )

      Rails.logger.info("Fulfilled driver request #{request.id[..7]} — " \
                        "Driver #{driver.name} → Shipment ##{short_id(request.shipment_id)}")
    end

    def short_shipment_id
      short_id(shipment_id)
    end

    def short_id(id)
      hex = id.delete("-").last(5).upcase
      "#{hex[0..2]}-#{hex[3..4]}"
    end
  end
end
