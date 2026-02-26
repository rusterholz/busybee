# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::MarkShipmentPackedWorker do
  it "transitions the shipment to packed" do
    wh = Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0)
    shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, status: "pending")

    execute_worker(described_class, variables: { shipment_id: shipment.id })

    expect(shipment.reload.status).to eq("packed")
  end
end
