# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Window do
  let(:now) { Time.utc(2026, 11, 13, 12, 0, 0) }

  it "defaults to the last hour in one-minute buckets" do
    window = described_class.new(nil, now: now)

    expect([window.key, window.from, window.to, window.bucket]).to eq(["1h", now - 1.hour, now, 1.minute])
  end

  it "reads each offered range, and falls back to the default for anything else" do
    expect(described_class::KEYS.map { |key| described_class.new(key, now: now).bucket }).
      to eq([30.seconds, 1.minute, 5.minutes])
    expect(described_class.new("2d", now: now).key).to eq("1h")
  end

  it "lists every bucket start from the one holding `from` through the one holding `to`" do
    buckets = described_class.new("15m", now: now + 10.seconds).buckets

    expect([buckets.first, buckets.last, buckets.size]).to eq([now - 15.minutes, now, 31])
  end

  it "converts a per-bucket count to a per-minute rate" do
    expect(described_class.new("15m", now: now).per_minute(3)).to eq(6.0)
  end
end
