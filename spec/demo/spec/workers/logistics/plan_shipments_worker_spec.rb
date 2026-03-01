# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::PlanShipmentsWorker do
  let(:warehouses) do
    [
      { "id" => "wh-a", "distance" => 2.0, "address" => { "lat" => 5.0, "lon" => 5.0 } },
      { "id" => "wh-b", "distance" => 5.0, "address" => { "lat" => -5.0, "lon" => -5.0 } }
    ]
  end

  it "plans a single shipment when one warehouse covers all items" do
    items = [
      { "type" => "widget", "qty" => 2, "available_at" => %w[wh-a wh-b] },
      { "type" => "gadget", "qty" => 1, "available_at" => %w[wh-a] }
    ]

    result = execute_worker(described_class, variables: { warehouses: warehouses, items: items })

    expect(result[:planned_shipments].size).to eq(1)
    expect(result[:planned_shipments].first[:warehouse_id]).to eq("wh-a")
  end

  it "splits across warehouses when no single one covers all items" do
    items = [
      { "type" => "widget", "qty" => 1, "available_at" => %w[wh-a] },
      { "type" => "gadget", "qty" => 1, "available_at" => %w[wh-b] }
    ]

    result = execute_worker(described_class, variables: { warehouses: warehouses, items: items })

    expect(result[:planned_shipments].size).to eq(2)
    ids = result[:planned_shipments].map { |s| s[:warehouse_id] }.sort
    expect(ids).to eq(%w[wh-a wh-b])
  end
end
