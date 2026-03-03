# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::UpdateOrderStatusWorker do
  let(:order) do
    Oms::Order.create!(
      customer_name: "Test", address_line_1: "123 Main", city: "Town",
      state: "CA", zip: "90210", lat: 0, lon: 0
    )
  end

  %w[processing packed shipping fulfilled].each do |target_status|
    it "transitions the order to #{target_status}" do
      execute_worker(described_class, variables: { order_id: order.id }, headers: { status: target_status })
      expect(order.reload.status).to eq(target_status)
    end
  end

  it "fails the job on an invalid status" do
    job = build_worker_job(variables: { order_id: order.id }, headers: { status: "bogus" })
    described_class.perform_job(job)
    expect(job).to be_failed
  end
end
