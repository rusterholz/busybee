# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::StartPrepareOrder do
  let(:order) do
    Oms::Order.create!(
      customer_name: "Alice", lat: 5.3, lon: -2.1,
      address_line_1: "123 Main", city: "Town", state: "CA", zip: "90210"
    ).tap do |o|
      Oms::LineItem.create!(order: o, item_type: "wireless-mouse", quantity: 2)
      o.reload
    end
  end

  it "starts the prepare_order process with the order's JSON" do
    client = instance_double(Busybee::Client, start_instance: 12_345)
    allow(Busybee::Client).to receive(:new).and_return(client)

    described_class.call(order)

    expect(client).to have_received(:start_instance).with(
      "prepare_order",
      vars: { order: order.as_json }
    )
  end

  it "updates the prepare_order_instance_key on the order" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_return(12_345) # rubocop:disable RSpec/MessageChain

    described_class.call(order)

    expect(order.reload.prepare_order_instance_key).to eq(12_345)
  end

  it "rescues errors and logs them without re-raising" do
    chain = receive_message_chain(:new, :start_instance) # rubocop:disable RSpec/MessageChain
    allow(Busybee::Client).to chain.and_raise(StandardError, "connection refused")
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(order) }.not_to raise_error

    expect(Rails.logger).to have_received(:error).with(/StartPrepareOrder.*connection refused/)
  end

  it "leaves instance key nil when start_instance fails" do
    allow(Busybee::Client).to receive_message_chain(:new, :start_instance).and_raise(StandardError, "timeout") # rubocop:disable RSpec/MessageChain
    allow(Rails.logger).to receive(:error)

    described_class.call(order)

    expect(order.reload.prepare_order_instance_key).to be_nil
  end
end
