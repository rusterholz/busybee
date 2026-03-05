# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::UpdateShipmentStatusWorker do
  let(:warehouse) { Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0) }

  def execute_update_shipment_worker(shipment, status:)
    execute_worker(described_class, variables: { shipment_id: shipment.id }, headers: { status: status })
  end

  describe "packed" do
    it "transitions the shipment to packed" do
      shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned")

      result = execute_update_shipment_worker(shipment, status: "packed")

      expect(shipment.reload.status).to eq("packed")
      expect(result).to eq(first_in_transit: nil, all_delivered: nil)
    end
  end

  describe "in_transit" do
    it "transitions and returns first_in_transit true when this is the only in-transit shipment" do
      shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "packed")

      result = execute_update_shipment_worker(shipment, status: "in_transit")

      expect(shipment.reload.status).to eq("in_transit")
      expect(result[:first_in_transit]).to be true
    end

    it "returns first_in_transit false when another shipment is already in transit" do
      Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")
      shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "packed")

      result = execute_update_shipment_worker(shipment, status: "in_transit")

      expect(result[:first_in_transit]).to be false
    end
  end

  describe "delivered" do
    it "transitions and returns all_delivered true when every shipment is now delivered" do
      Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "delivered")
      shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")

      result = execute_update_shipment_worker(shipment, status: "delivered")

      expect(shipment.reload.status).to eq("delivered")
      expect(result[:all_delivered]).to be true
    end

    it "returns all_delivered false when other shipments remain undelivered" do
      Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned")
      shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")

      result = execute_update_shipment_worker(shipment, status: "delivered")

      expect(result[:all_delivered]).to be false
    end
  end

  it "fails the job on an invalid status" do
    shipment = Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned")

    job = build_test_job(variables: { shipment_id: shipment.id }, headers: { status: "bogus" })
    expect do
      execute_worker(described_class, job: job)
    end.to raise_error(ArgumentError, /Invalid shipment status/)
    expect(job).to be_failed
  end
end
