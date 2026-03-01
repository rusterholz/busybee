# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::MarkOrderShippedWorker do
  it "transitions the order to shipping" do
    order = Oms::Order.create!(
      customer_name: "Test", address_line_1: "123 Main", city: "Town",
      state: "CA", zip: "90210", lat: 0, lon: 0, status: "processing"
    )

    execute_worker(described_class, variables: { order_id: order.id })

    expect(order.reload.status).to eq("shipping")
  end
end
