# frozen_string_literal: true

require "busybee/client/call/timestamps"

RSpec.describe Busybee::Client::Call::Timestamps do
  # The monotonic clock can't be controlled, so these assert ordering/sign and
  # nil-until-stamped semantics rather than exact durations.
  it "stamps created_at at construction" do
    expect(described_class.new.created_at).to be_a(Time)
  end

  it "leaves resolved_at and total_ms nil until resolved" do
    ts = described_class.new
    expect(ts.resolved_at).to be_nil
    expect(ts.total_ms).to be_nil
  end

  it "stamps resolved_at and computes a non-negative total_ms on resolve" do
    ts = described_class.new
    ts.stamp_resolved!
    expect(ts.resolved_at).to be_a(Time)
    expect(ts.total_ms).to be >= 0
  end

  it "computes a non-negative network_ms across an attempt's network bracket" do
    ts = described_class.new
    ts.begin_network
    ts.end_network
    expect(ts.network_ms).to be >= 0
  end

  it "leaves queue_ms nil before the first attempt starts" do
    expect(described_class.new.queue_ms).to be_nil
  end

  it "computes a non-negative queue_ms from construction to the first attempt start" do
    ts = described_class.new
    ts.begin_network
    expect(ts.queue_ms).to be >= 0
  end

  it "has nil backoff_ms on the first attempt" do
    ts = described_class.new
    ts.begin_network
    ts.end_network
    expect(ts.backoff_ms).to be_nil
  end

  it "computes a non-negative backoff_ms on a retry, readable post-yield" do
    ts = described_class.new
    ts.begin_network
    ts.end_network             # attempt 1 finished
    ts.begin_network           # attempt 2 started
    ts.end_network             # post-yield: prior finish still the backoff basis
    expect(ts.backoff_ms).to be >= 0
  end

  it "accumulates network time across attempts" do
    ts = described_class.new
    ts.begin_network
    ts.end_network
    first = ts.cumulative_network_ms
    ts.begin_network
    ts.end_network
    expect(ts.cumulative_network_ms).to be >= first
  end
end
