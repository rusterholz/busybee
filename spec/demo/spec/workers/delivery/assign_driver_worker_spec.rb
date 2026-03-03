# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::AssignDriverWorker do
  it "assigns the available driver with the lowest mileage and creates a request" do
    Delivery::Driver.create!(name: "Alice", total_mileage: 100.0)
    bob = Delivery::Driver.create!(name: "Bob", total_mileage: 50.0)

    result = execute_worker(described_class, variables: { shipment_id: "ship-1" })

    expect(result[:driver_id]).to eq(bob.id)
    expect(result[:driver_name]).to eq("Bob")
    expect(result[:request_id]).to be_present
    expect(bob.reload.current_shipment_id).to eq("ship-1")

    request = Delivery::DriverRequest.find(result[:request_id])
    expect(request.driver_id).to eq(bob.id)
    expect(request.shipment_id).to eq("ship-1")
  end

  it "returns nil driver info and creates an open request when no drivers are available" do
    busy = Delivery::Driver.create!(name: "Alice", total_mileage: 0, current_shipment_id: "ship-other")

    result = execute_worker(described_class, variables: { shipment_id: "ship-1" })

    expect(result[:driver_id]).to be_nil
    expect(result[:driver_name]).to be_nil
    expect(result[:request_id]).to be_present

    request = Delivery::DriverRequest.find(result[:request_id])
    expect(request.driver_id).to be_nil
    expect(request.shipment_id).to eq("ship-1")

    # Busy driver should not have been reassigned
    expect(busy.reload.current_shipment_id).to eq("ship-other")
  end
end
