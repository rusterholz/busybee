# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::Shipment do
  let(:warehouse) do
    Logistics::Warehouse.create!(id: SecureRandom.uuid, name: "West Hub", lat: 34.0, lon: -118.2)
  end

  let(:shipment) do
    described_class.create!(
      id: SecureRandom.uuid, order_id: SecureRandom.uuid,
      warehouse: warehouse, status: "pending",
      items: [{ "type" => "widget", "qty" => 3 }, { "type" => "gadget", "qty" => 2 }]
    )
  end

  describe "#item_count" do
    it "sums qty across all items" do
      expect(shipment.item_count).to eq(5)
    end

    it "defaults missing qty to 1" do
      shipment.update!(items: [{ "type" => "widget" }, { "type" => "gadget", "qty" => 4 }])
      expect(shipment.item_count).to eq(5)
    end

    it "returns 0 for nil items" do
      shipment.update!(items: nil)
      expect(shipment.item_count).to eq(0)
    end
  end

  describe "#as_json" do
    it "returns the maximal representation" do
      json = shipment.as_json
      expect(json).to eq({
                           id: shipment.id,
                           order_id: shipment.order_id,
                           item_count: 5,
                           warehouse: { id: warehouse.id, address: { lat: 34.0, lon: -118.2 } }
                         })
    end
  end

  describe ".for_order" do
    it "scopes to a specific order" do
      expect(described_class.for_order(shipment.order_id)).to include(shipment)
      expect(described_class.for_order("nonexistent")).to be_empty
    end
  end

  describe ".by_status" do
    it "filters by status" do
      expect(described_class.by_status("pending")).to include(shipment)
      expect(described_class.by_status("packed")).not_to include(shipment)
    end
  end

  describe "callbacks" do
    it "delegates to StartDeliverShipment when status becomes packed" do
      allow(Logistics::StartDeliverShipment).to receive(:call)

      shipment.update!(status: "packed")
      shipment.send(:start_deliver_shipment)

      expect(Logistics::StartDeliverShipment).to have_received(:call).with(shipment)
    end

    it "does not start deliver_shipment when status changes to something other than packed" do
      allow(Logistics::StartDeliverShipment).to receive(:call)

      shipment.update!(status: "delivered")
      shipment.send(:start_deliver_shipment)

      expect(Logistics::StartDeliverShipment).not_to have_received(:call)
    end
  end
end
