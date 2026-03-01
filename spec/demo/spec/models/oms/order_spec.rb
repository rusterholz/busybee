# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::Order do
  let(:order) do
    described_class.create!(
      id: SecureRandom.uuid, customer_name: "Alice", lat: 40.7, lon: -74.0,
      address_line_1: "123 Main St", city: "New York", state: "NY", zip: "10001"
    ).tap do |o|
      Oms::LineItem.create!(id: SecureRandom.uuid, order: o, item_type: "widget", quantity: 3)
      Oms::LineItem.create!(id: SecureRandom.uuid, order: o, item_type: "gadget", quantity: 1)
      o.reload
    end
  end

  describe "#as_json" do
    it "returns the full order representation" do
      json = order.as_json
      expect(json[:id]).to eq(order.id)
      expect(json[:address]).to eq({ lat: 40.7, lon: -74.0 })
      expect(json[:items]).to contain_exactly(
        { type: "widget", qty: 3 },
        { type: "gadget", qty: 1 }
      )
    end
  end

  describe ".by_status" do
    it "filters orders by status" do
      order # ensure created
      expect(described_class.by_status("submitted")).to include(order)
      expect(described_class.by_status("processing")).not_to include(order)
    end
  end

  describe "callbacks" do
    it "restocks inventory via the restock callback" do
      allow(Sim::GuaranteedRestock).to receive(:call)

      order.send(:restock_inventory)

      expect(Sim::GuaranteedRestock).to have_received(:call).with(order)
    end

    it "delegates to StartPrepareOrder" do
      allow(Oms::StartPrepareOrder).to receive(:call)

      order.send(:start_prepare_order)

      expect(Oms::StartPrepareOrder).to have_received(:call).with(order)
    end

    it "delegates to StartShipOrder when status becomes processing" do
      allow(Oms::StartShipOrder).to receive(:call)

      order.update!(status: "processing")
      order.send(:start_ship_order)

      expect(Oms::StartShipOrder).to have_received(:call).with(order)
    end

    it "does not start ship_order when status changes to something other than processing" do
      allow(Oms::StartShipOrder).to receive(:call)

      order.update!(status: "shipping")
      order.send(:start_ship_order)

      expect(Oms::StartShipOrder).not_to have_received(:call)
    end
  end
end
