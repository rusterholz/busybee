# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::StartShipOrder do
  let(:order) do
    Oms::Order.create!(
      customer_name: "Bob", lat: 1.0, lon: 2.0,
      address_line_1: "456 Elm", city: "City", state: "NY", zip: "10001",
      status: "processing"
    )
  end

  it "starts the ship_order process with only the order ID" do
    client = instance_double(Busybee::Client, start_instance: 67_890)
    allow(Busybee::Client).to receive(:new).and_return(client)

    described_class.call(order)

    expect(client).to have_received(:start_instance).with(
      "ship_order",
      vars: { order: { id: order.id } }
    )
  end

  it "updates the ship_order_instance_key on the order" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_return(67_890) # rubocop:disable RSpec/MessageChain

    described_class.call(order)

    expect(order.reload.ship_order_instance_key).to eq(67_890)
  end

  it "rescues errors and logs them without re-raising" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_raise(StandardError, "unavailable") # rubocop:disable RSpec/MessageChain
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(order) }.not_to raise_error

    expect(Rails.logger).to have_received(:error).with(/StartShipOrder.*unavailable/)
  end

  it "leaves instance key nil when start_instance fails" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_raise(StandardError, "timeout") # rubocop:disable RSpec/MessageChain
    allow(Rails.logger).to receive(:error)

    described_class.call(order)

    expect(order.reload.ship_order_instance_key).to be_nil
  end
end
