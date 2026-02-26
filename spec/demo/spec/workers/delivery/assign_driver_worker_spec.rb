# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::AssignDriverWorker do
  it "assigns the available driver with the lowest mileage" do
    Delivery::Driver.create!(name: "Alice", total_mileage: 100.0)
    bob = Delivery::Driver.create!(name: "Bob", total_mileage: 50.0)

    result = execute_worker(described_class, variables: { shipment_id: "ship-1" })

    expect(result).to eq(driver_id: bob.id, driver_name: "Bob")
    expect(bob.reload.current_shipment_id).to eq("ship-1")
  end
end
