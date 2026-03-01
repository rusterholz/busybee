# frozen_string_literal: true

module Delivery
  # All drivers may be mid-delivery when a new shipment needs one. The backoff
  # gives in-flight deliveries time to complete and free up a driver, scaled by
  # the simulation speed so retries stay proportional at any tempo.
  #
  # When all drivers are busy, the worker recruits a new driver inline (up to
  # max_drivers, which scales with simulation speed via 4*sqrt(speed)) rather
  # than backing off and retrying.
  class AssignDriverWorker < Busybee::Worker
    description "Assigns the available driver with the lowest total mileage to a shipment"
    backoff (50.0 / Rails.application.config.x.demo.simulation_speed).seconds

    variable :shipment_id, type: :uuid, description: "Shipment to assign a driver to"

    output :driver_id,   type: :uuid,   description: "Assigned driver's ID"
    output :driver_name, type: :string, description: "Assigned driver's name"

    def perform
      driver = find_or_recruit_driver!

      Rails.logger.info("Assigned Driver #{driver.name} to Shipment ##{short_shipment_id}")
      { driver_id: driver.id, driver_name: driver.name }
    end

    private

    def find_or_recruit_driver!
      Driver.transaction do
        available = Driver.available.by_mileage.first
        available ||= recruit_driver! if should_recruit?
        raise ActiveRecord::RecordNotFound, "No drivers available" unless available

        available.tap { |d| d.update!(current_shipment_id: shipment_id) }
      end
    end

    def should_recruit?
      Driver.count < max_drivers
    end

    def max_drivers
      speed = Rails.application.config.x.demo.simulation_speed
      (4 * Math.sqrt(speed)).ceil
    end

    def recruit_driver!
      Driver.create!(name: Faker::Name.name, total_mileage: 0.0).tap do |d|
        total = Driver.count
        avail = Driver.available.count
        Rails.logger.info("Recruited Driver #{d.name} (fleet: #{total}/#{max_drivers} max, #{avail} idle)")
      end
    end

    def short_shipment_id
      hex = shipment_id.delete("-").last(5).upcase
      "#{hex[0..2]}-#{hex[3..4]}"
    end
  end
end
