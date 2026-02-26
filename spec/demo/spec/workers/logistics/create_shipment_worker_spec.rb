# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::CreateShipmentWorker do
  it "creates a shipment and decrements stock" do
    wh = Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0)
    Logistics::StockItem.create!(warehouse: wh, item_type: "widget", quantity: 10)

    result = execute_worker(described_class, variables: {
                              order_id: "order-1", warehouse_id: wh.id,
                              items: [{ "type" => "widget", "qty" => 3 }]
                            })

    expect(result[:shipment_id]).to be_present
    expect(result[:item_count]).to eq(3)
    expect(Logistics::StockItem.find_by(warehouse: wh, item_type: "widget").quantity).to eq(7)
  end
end
