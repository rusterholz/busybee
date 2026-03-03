# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::CompleteDriverDeliveryWorker do
  it "adds mileage and clears the shipment assignment" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")

    execute_worker(described_class, variables: {
                     driver_id: driver.id, shipment_id: "ship-1", distance: 12.5
                   })

    driver.reload
    expect(driver.total_mileage).to eq(62.5)
    expect(driver.current_shipment_id).to be_nil
  end

  it "retires an idle driver when the fleet is oversized" do
    # 4 drivers (above MIN_DRIVER_COUNT of 3), all idle except the one delivering
    old_enough = 10.minutes.ago
    completing = Delivery::Driver.create!(name: "A", total_mileage: 0, current_shipment_id: "ship-1",
                                          created_at: old_enough)
    Delivery::Driver.create!(name: "B", total_mileage: 0, created_at: old_enough)
    Delivery::Driver.create!(name: "C", total_mileage: 0, created_at: old_enough)
    Delivery::Driver.create!(name: "D", total_mileage: 0, created_at: old_enough)

    job = build_worker_job(variables: { driver_id: completing.id, shipment_id: "ship-1", distance: 5.0 })
    described_class.perform_job(job)

    # Job must complete without error — not just appear to work via side effects
    expect(job).not_to be_failed

    # After completing, the driver should be retired (fleet was oversized with 75% idle)
    expect(Delivery::Driver.find_by(id: completing.id)).to be_nil
    expect(Delivery::Driver.count).to eq(3)
  end
end
