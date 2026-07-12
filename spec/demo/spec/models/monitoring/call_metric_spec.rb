# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::CallMetric do
  def metric(name = "engine_call") = described_class.find_by(metric_name: name)

  describe ".observe" do
    it "folds observations into count, min, max and an exponential moving average" do
      [10.0, 20.0, 30.0].each { |v| described_class.observe("engine_call", { rpc: "activate_jobs" }, v) }

      expect(metric).to have_attributes(count: 3, minimum: 10.0, maximum: 30.0)
      expect(metric.ewma).to be_within(0.001).of(12.9) # 10 → 11 → 12.9 at α=0.1
    end

    it "tracks an exponentially-weighted variance" do
      [10.0, 20.0, 30.0].each { |v| described_class.observe("engine_call", { rpc: "activate_jobs" }, v) }

      expect(metric.ewmv).to be_within(0.001).of(40.59) # 0 → 9 → 40.59 at α=0.1
      expect(metric.stddev).to be_within(0.001).of(Math.sqrt(40.59))
    end

    it "double-counts a re-delivered sample (at-least-once, no dedup by design)" do
      2.times { described_class.observe("engine_call", { rpc: "activate_jobs" }, 5.0) }

      expect(metric.count).to eq(2)
    end
  end

  describe "keying" do
    it "aggregates separately per (metric_name, tag tuple)" do
      described_class.observe("engine_call", { rpc: "activate_jobs" }, 5.0)
      described_class.observe("engine_call", { rpc: "complete_job" }, 5.0)
      described_class.observe("engine_call", { rpc: "activate_jobs" }, 9.0)

      expect(described_class.where(metric_name: "engine_call").count).to eq(2)
      expect(described_class.find_by(tag_key: described_class.tag_key(rpc: "activate_jobs")).count).to eq(2)
    end

    it "keys by the tag tuple regardless of key order" do
      described_class.observe("engine_call", { rpc: "x", worker: "w" }, 1.0)
      described_class.observe("engine_call", { worker: "w", rpc: "x" }, 1.0)

      expect(described_class.where(metric_name: "engine_call").count).to eq(1)
      expect(metric.count).to eq(2)
    end
  end

  describe "concurrent folding", :no_transaction do
    it "loses no updates under concurrent observers (atomic SQL, not read-modify-write)" do
      name = "concurrent-#{SecureRandom.hex(4)}"

      threads = 4.times.map do
        Thread.new do
          Monitoring::Record.connection_pool.with_connection do
            25.times { described_class.observe(name, { rpc: "activate_jobs" }, 1.0) }
          end
        end
      end
      threads.each(&:join)

      expect(described_class.find_by(metric_name: name).count).to eq(100)
    ensure
      described_class.where(metric_name: name).delete_all
    end
  end
end
