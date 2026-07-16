# frozen_string_literal: true

require "busybee/worker/timestamps"

RSpec.describe Busybee::Worker::Timestamps do
  # The monotonic clock can't be controlled, so these assert ordering/sign and
  # nil-until-stamped semantics rather than exact durations.
  it "leaves every moment nil until it is stamped" do
    ts = described_class.new
    expect(ts.started_at).to be_nil
    expect(ts.stop_requested_at).to be_nil
    expect(ts.stopping_at).to be_nil
    expect(ts.shutdown_at).to be_nil
  end

  it "stamps a moment as a UTC Time and a monotonic Float" do
    ts = described_class.new
    ts.stamp!(:started_at)
    expect(ts.started_at).to be_a(Time)
    expect(ts.started_at(:monotonic)).to be_a(Float)
  end

  it "defaults the reader kind to :utc" do
    ts = described_class.new.tap { |t| t.stamp!(:started_at) }
    expect(ts.started_at).to eq(ts.started_at(:utc))
  end

  it "raises on an unknown reader kind" do
    ts = described_class.new.tap { |t| t.stamp!(:started_at) }
    expect { ts.started_at(:bogus) }.to raise_error(ArgumentError, /:utc or :monotonic/)
  end

  it "returns self from stamp! for chaining" do
    ts = described_class.new
    expect(ts.stamp!(:started_at)).to be(ts)
  end

  describe "computed durations" do
    it "are nil until both endpoints are stamped" do
      ts = described_class.new
      expect(ts.stop_duration_ms).to be_nil
      expect(ts.stop_latency_ms).to be_nil
    end

    it "computes a non-negative stop_duration_ms (stopping → shutdown)" do
      ts = described_class.new
      ts.stamp!(:stopping_at)
      ts.stamp!(:shutdown_at)
      expect(ts.stop_duration_ms).to be >= 0
    end

    it "computes a non-negative stop_latency_ms (stop_requested → stopping)" do
      ts = described_class.new
      ts.stamp!(:stop_requested_at)
      ts.stamp!(:stopping_at)
      expect(ts.stop_latency_ms).to be >= 0
    end

    it "computes uptime_s as live seconds since started_at, re-read each call" do
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).
        and_return(100.0, 105.5, 107.2)
      ts = described_class.new
      expect(ts.uptime_s).to be_nil
      ts.stamp!(:started_at)
      expect(ts.uptime_s).to eq(5.5)
      expect(ts.uptime_s).to eq(7.2) # ticking: no shutdown stamp needed
    end
  end
end
