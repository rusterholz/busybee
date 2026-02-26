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

  describe "#on_create_start_prepare_order" do
    it "starts the prepare_order process with full order JSON" do
      client = instance_double(Busybee::Client, start_instance: 12_345)
      allow(Busybee::Client).to receive(:new).and_return(client)
      allow(Sim::GuaranteedRestock).to receive(:call)

      order.send(:on_create_start_prepare_order)

      expect(Sim::GuaranteedRestock).to have_received(:call).with(order)
      expect(client).to have_received(:start_instance).with(
        "prepare_order",
        vars: { order: order.as_json }
      )
    end
  end

  describe "#on_processing_start_ship_order" do
    it "starts the ship_order process with only the order ID" do
      client = instance_double(Busybee::Client, start_instance: 67_890)
      allow(Busybee::Client).to receive(:new).and_return(client)

      order.update!(status: "processing")
      order.send(:on_processing_start_ship_order)

      expect(client).to have_received(:start_instance).with(
        "ship_order",
        vars: { order: { id: order.id } }
      )
    end

    it "does not fire when status changes to something other than processing" do
      allow(Busybee::Client).to receive(:new)

      order.update!(status: "shipping")
      order.send(:on_processing_start_ship_order)

      expect(Busybee::Client).not_to have_received(:new)
    end
  end
end
