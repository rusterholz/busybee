# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::MarkShipmentDeliveredWorker do
  it "transitions shipment and checks all-delivered" do
    wh = Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0)
    s1 = Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, status: "in_transit")
    Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, status: "delivered")

    result = execute_worker(described_class, variables: { shipment_id: s1.id, order_id: "order-1" })

    expect(s1.reload.status).to eq("delivered")
    expect(result[:all_delivered]).to be true
  end

  it "returns false when other shipments remain undelivered" do
    wh = Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0)
    s1 = Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, status: "in_transit")
    Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, status: "planned")

    result = execute_worker(described_class, variables: { shipment_id: s1.id, order_id: "order-1" })

    expect(result[:all_delivered]).to be false
  end
end
