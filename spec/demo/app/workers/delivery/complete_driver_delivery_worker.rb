# frozen_string_literal: true

module Delivery
  # After a delivery, retires the driver if the fleet is oversized — more than
  # 40% idle and above the minimum baseline (3). A cooldown period (125/speed
  # seconds) prevents newly recruited drivers from being immediately retired,
  # damping oscillation. This balances AssignDriverWorker's recruitment (which
  # fires when ALL drivers are busy), targeting ~60% fleet utilization.
  class CompleteDriverDeliveryWorker < Busybee::Worker
    MIN_DRIVER_COUNT = 3

    @last_retirement_at = Concurrent::AtomicReference.new(0.0)

    description "Records delivery completion: adds mileage and releases the driver"

    variable :driver_id,   type: :uuid,    description: "Driver who completed the delivery"
    variable :shipment_id, type: :uuid,    description: "Shipment that was delivered"
    variable :distance,    type: :decimal, description: "Distance traveled for this delivery"

    def perform
      driver = Driver.find(driver_id)
      new_mileage = driver.total_mileage + BigDecimal(distance.to_s)
      driver.update!(total_mileage: new_mileage, current_shipment_id: nil)

      Rails.logger.info("Driver #{driver.name} completed Shipment ##{short_shipment_id} " \
                        "(+#{distance} miles, total: #{new_mileage.round(1)})")

      maybe_retire!(driver)
    end

    private

    def maybe_retire!(driver)
      total = Driver.count
      return if total <= MIN_DRIVER_COUNT
      return if Driver.available.count * 5 <= total * 2
      return if driver.created_at > retirement_cooldown.ago
      return if retired_too_recently?

      record_retirement!
      driver.destroy!
      avail = Driver.available.count
      remaining = total - 1
      Rails.logger.info("Retired Driver #{driver.name} (fleet: #{remaining}, #{avail} idle, " \
                        "#{((remaining - avail) * 100.0 / remaining).round}% utilized)")
    end

    def retired_too_recently?
      elapsed_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) -
                   self.class.instance_variable_get(:@last_retirement_at).get
      elapsed_ms < retirement_interval_ms
    end

    def record_retirement!
      self.class.instance_variable_get(:@last_retirement_at)
                .set(Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond))
    end

    def retirement_interval_ms
      speed = Rails.application.config.x.demo.simulation_speed
      [1000, 250_000.0 / speed].max
    end

    def retirement_cooldown
      speed = Rails.application.config.x.demo.simulation_speed
      [1, 125.0 / speed].max.seconds
    end

    def short_shipment_id
      hex = shipment_id.delete("-").last(5).upcase
      "#{hex[0..2]}-#{hex[3..4]}"
    end
  end
end
