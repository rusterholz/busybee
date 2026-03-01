# frozen_string_literal: true

require_relative "../rails_helper"
require "rack/test"

RSpec.describe "Retry process start endpoints" do # rubocop:disable RSpec/DescribeClass
  include Rack::Test::Methods

  def app
    Rails.application
  end

  describe "POST /orders/:id/start_prepare_order" do
    it "calls StartPrepareOrder and redirects to order" do
      allow(Oms::StartPrepareOrder).to receive(:call)

      order = Oms::Order.create!(
        customer_name: "Alice", lat: 1.0, lon: 2.0,
        address_line_1: "123 Main", city: "Town", state: "CA", zip: "90210"
      )

      post "/orders/#{order.id}/start_prepare_order"

      expect(Oms::StartPrepareOrder).to have_received(:call).with(order)
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include("/orders/#{order.id}")
    end
  end

  describe "POST /orders/:id/start_ship_order" do
    it "calls StartShipOrder and redirects to order" do
      allow(Oms::StartShipOrder).to receive(:call)

      order = Oms::Order.create!(
        customer_name: "Bob", lat: 1.0, lon: 2.0,
        address_line_1: "456 Elm", city: "City", state: "NY", zip: "10001",
        status: "processing"
      )

      post "/orders/#{order.id}/start_ship_order"

      expect(Oms::StartShipOrder).to have_received(:call).with(order)
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include("/orders/#{order.id}")
    end
  end

  describe "POST /shipments/:id/start_deliver_shipment" do
    it "calls StartDeliverShipment and redirects to the shipment's order" do
      allow(Logistics::StartDeliverShipment).to receive(:call)

      warehouse = Logistics::Warehouse.create!(name: "West Hub", lat: -6.0, lon: 5.0)
      order_id = SecureRandom.uuid
      shipment = Logistics::Shipment.create!(
        order_id: order_id, warehouse: warehouse, status: "packed",
        items: [{ "type" => "webcam", "qty" => 1 }]
      )

      post "/shipments/#{shipment.id}/start_deliver_shipment"

      expect(Logistics::StartDeliverShipment).to have_received(:call).with(shipment)
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include("/orders/#{order_id}")
    end
  end
end
