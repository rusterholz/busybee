# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::StartDeliverShipment do
  let(:warehouse) do
    Logistics::Warehouse.create!(name: "West Hub", lat: -6.0, lon: 5.0)
  end

  let(:shipment) do
    Logistics::Shipment.create!(
      order_id: SecureRandom.uuid, warehouse: warehouse, status: "packed",
      items: [{ "type" => "webcam", "qty" => 1 }]
    )
  end

  it "starts the deliver_shipment process with shipment JSON (no item_count)" do
    client = instance_double(Busybee::Client, start_instance: 99_999)
    allow(Busybee::Client).to receive(:new).and_return(client)

    described_class.call(shipment)

    expect(client).to have_received(:start_instance).with(
      "deliver_shipment",
      vars: {
        shipment: {
          id: shipment.id,
          order_id: shipment.order_id,
          warehouse: { id: warehouse.id, address: { lat: -6.0, lon: 5.0 } }
        }
      }
    )
  end

  it "updates the deliver_shipment_instance_key on the shipment" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_return(99_999) # rubocop:disable RSpec/MessageChain

    described_class.call(shipment)

    expect(shipment.reload.deliver_shipment_instance_key).to eq(99_999)
  end

  it "rescues errors and logs them without re-raising" do
    chain = receive_message_chain(:new, :start_instance) # rubocop:disable RSpec/MessageChain
    allow(Busybee::Client).to chain.and_raise(StandardError, "connection refused")
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(shipment) }.not_to raise_error

    expect(Rails.logger).to have_received(:error).with(/StartDeliverShipment.*connection refused/)
  end

  it "leaves instance key nil when start_instance fails" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_raise(StandardError, "timeout") # rubocop:disable RSpec/MessageChain
    allow(Rails.logger).to receive(:error)

    described_class.call(shipment)

    expect(shipment.reload.deliver_shipment_instance_key).to be_nil
  end
end
