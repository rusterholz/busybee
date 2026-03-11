# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::UpdateShipmentStatusWorker do
  let(:warehouse) { Logistics::Warehouse.create!(name: "Alpha", lat: 0, lon: 0) }
  let(:variables) { { shipment_id: shipment.id } }
  let(:headers) { { status: status } }
  let(:job) { build_test_job(variables: variables, headers: headers) }

  describe "packed" do
    let(:shipment) { Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned") }
    let(:status) { "packed" }

    it "transitions the shipment and completes with no transit/delivery flags" do
      expect(described_class).to complete_job(job).
        with_vars(first_in_transit: nil, all_delivered: nil)
      expect(shipment.reload.status).to eq("packed")
    end
  end

  describe "in_transit" do
    let(:status) { "in_transit" }

    context "when this is the only in-transit shipment" do
      let(:shipment) { Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "packed") }

      it "transitions and returns first_in_transit true" do
        expect(described_class).to complete_job(job).
          with_vars(hash_including(first_in_transit: true))
        expect(shipment.reload.status).to eq("in_transit")
      end
    end

    context "when another shipment is already in transit" do
      let(:shipment) do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "packed")
      end

      before do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")
      end

      it "returns first_in_transit false" do
        expect(described_class).to complete_job(job).
          with_vars(hash_including(first_in_transit: false))
      end
    end
  end

  describe "delivered" do
    let(:status) { "delivered" }

    context "when every shipment is now delivered" do
      let(:shipment) do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")
      end

      before do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "delivered")
      end

      it "transitions and returns all_delivered true" do
        expect(described_class).to complete_job(job).
          with_vars(hash_including(all_delivered: true))
        expect(shipment.reload.status).to eq("delivered")
      end
    end

    context "when other shipments remain undelivered" do
      let(:shipment) do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "in_transit")
      end

      before do
        Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned")
      end

      it "returns all_delivered false" do
        expect(described_class).to complete_job(job).
          with_vars(hash_including(all_delivered: false))
      end
    end
  end

  context "with an invalid status" do
    let(:shipment) { Logistics::Shipment.create!(order_id: "order-1", warehouse: warehouse, status: "planned") }
    let(:status) { "bogus" }

    it "fails the job" do
      expect(described_class).to fail_job(job).
        with_error(ArgumentError, /Invalid shipment status/)
    end
  end
end
