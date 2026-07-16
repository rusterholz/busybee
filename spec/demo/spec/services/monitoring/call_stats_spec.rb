# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::CallStats do
  def observe(rpc:, worker_class:, value:)
    Monitoring::CallMetric.observe("engine_call", { rpc: rpc, worker_class: worker_class }, value)
  end

  # Two rpcs from one worker class, one from another.
  before do
    observe(rpc: "complete_job", worker_class: "Oms::UpdateOrderStatusWorker", value: 100.0)
    observe(rpc: "complete_job", worker_class: "Oms::UpdateOrderStatusWorker", value: 120.0)
    observe(rpc: "activate_jobs", worker_class: "Oms::UpdateOrderStatusWorker", value: 50.0)
    observe(rpc: "activate_jobs", worker_class: "Logistics::CreateShipmentWorker", value: 40.0)
  end

  it "totals every folded call" do
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
    it "groups by rpc with counts and a typical duration, busiest first" do
      by_rpc = described_class.new.by_rpc

      expect(by_rpc.map { |r| r[:rpc] }).to eq(%w[activate_jobs complete_job]) # 2 vs 2 — tie broken by name is fine
      complete = by_rpc.find { |r| r[:rpc] == "complete_job" }
      expect(complete).to include(count: 2, min_ms: 100.0, max_ms: 120.0)
      expect(complete[:mean_ms]).to be_within(0.001).of(102.0) # ewma 100 → 102 at α=0.1
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
