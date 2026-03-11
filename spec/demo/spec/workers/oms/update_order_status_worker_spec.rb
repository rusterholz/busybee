# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Oms::UpdateOrderStatusWorker do
  let(:order) do
    Oms::Order.create!(
      customer_name: "Test", address_line_1: "123 Main", city: "Town",
      state: "CA", zip: "90210", lat: 0, lon: 0
    )
  end
  let(:variables) { { order_id: order.id } }
  let(:headers) { { status: status } }
  let(:job) { build_test_job(variables: variables, headers: headers) }

  %w[processing packed shipping fulfilled].each do |target_status|
    context "with status #{target_status}" do
      let(:status) { target_status }

      it "transitions the order and completes the job" do
        expect(described_class).to complete_job(job)
        expect(order.reload.status).to eq(target_status)
      end
    end
  end

  context "with an invalid status" do
    let(:status) { "bogus" }

    it "fails the job" do
      expect(described_class).to fail_job(job).
        with_error(ArgumentError, /Invalid order status/)
    end
  end
end
