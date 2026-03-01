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
end
