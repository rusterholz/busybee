# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::LoadOrderAddressWorker do
  it "returns the order's coordinates" do
    order = Oms::Order.create!(
      customer_name: "Test", address_line_1: "123 Main", city: "Town",
      state: "CA", zip: "90210", lat: 3.5, lon: -7.2
    )

    result = execute_worker(described_class, variables: { order_id: order.id })

    expect(result).to eq(lat: 3.5, lon: -7.2)
  end
end
