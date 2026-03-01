# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::LoadOrderShipmentsWorker do
  it "returns shipments for the order" do
    wh = Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0)
    Logistics::Shipment.create!(order_id: "order-1", warehouse: wh, items: [{ "type" => "widget", "qty" => 2 }])

    result = execute_worker(described_class, variables: { order_id: "order-1" })

    expect(result[:shipments].size).to eq(1)
    expect(result[:shipments].first[:item_count]).to eq(2)
  end
end
