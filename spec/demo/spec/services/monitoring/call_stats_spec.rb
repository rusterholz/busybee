# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::CallStats, :busybee do
  def observe(rpc, worker_class, network:)
    status = build_test_worker_status(worker_class: worker_class)
    Monitoring::EngineCall.record(build_test_call(rpc, worker_status: status, network: network), seq: 1.0)
  end

  # Two rpcs from one worker class, one from another.
  before do
    observe(:complete_job, Oms::UpdateOrderStatusWorker, network: 10)
    observe(:complete_job, Oms::UpdateOrderStatusWorker, network: 30)
    observe(:activate_jobs, Oms::UpdateOrderStatusWorker, network: 1)
    observe(:activate_jobs, Logistics::CreateShipmentWorker, network: 1)
  end

  it "totals every recorded call" do
    expect(described_class.new.total_calls).to eq(4)
  end

  describe "#calls_per_job" do
    it "divides total calls by the job count" do
      expect(described_class.new.calls_per_job(2)).to eq(2.0)
    end

    it "is zero when no jobs ran (no divide-by-zero)" do
      expect(described_class.new.calls_per_job(0)).to eq(0.0)
    end
  end

  describe "#by_rpc" do
    it "groups by rpc with counts and exact duration stats over the raw calls" do
      complete = described_class.new.by_rpc.find { |r| r[:rpc] == "complete_job" }
      network = Monitoring::EngineCall.where(rpc: "complete_job").pluck(:network_ms)

      expect(complete).to include(count: 2, min_ms: network.min, max_ms: network.max)
      expect(complete[:mean_ms]).to be_within(0.001).of(network.sum / 2)
      expect(network.max).to be > 25
    end
  end

  describe "#by_worker" do
    it "groups by worker class, each with its own rpc breakdown" do
      oms = described_class.new.by_worker.find { |w| w[:worker_class] == "Oms::UpdateOrderStatusWorker" }

      expect(oms[:count]).to eq(3)
      expect(oms[:rpcs].map { |r| r[:rpc] }).to contain_exactly("complete_job", "activate_jobs")
    end
  end
end
