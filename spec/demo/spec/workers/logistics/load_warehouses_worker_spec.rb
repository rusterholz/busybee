# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::LoadWarehousesWorker do
  it "returns all warehouses with address data" do
    Logistics::Warehouse.create!(name: "Alpha", lat: 5.0, lon: -5.0)
    Logistics::Warehouse.create!(name: "Beta", lat: -3.0, lon: 4.0)

    result = execute_worker(described_class)

    expect(result[:warehouses].size).to eq(2)
    expect(result[:warehouses].first).to include(:id, :name, :address)
  end
end
