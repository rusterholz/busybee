# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::LoadItemAvailabilityWorker do
  it "returns warehouse IDs that stock the item" do
    wh1 = Logistics::Warehouse.create!(name: "A", lat: 0, lon: 0)
    wh2 = Logistics::Warehouse.create!(name: "B", lat: 1, lon: 1)
    Logistics::StockItem.create!(warehouse: wh1, item_type: "widget", quantity: 10)
    Logistics::StockItem.create!(warehouse: wh2, item_type: "widget", quantity: 0)

    result = execute_worker(described_class, variables: { item_type: "widget" })

    expect(result[:warehouse_ids]).to eq([wh1.id])
  end
end
