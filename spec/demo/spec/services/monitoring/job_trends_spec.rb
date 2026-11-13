# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::JobTrends do
  subject(:trends) { described_class.new(Monitoring::JobRun.all, window) }

  let(:now) { Time.zone.at(Time.current.to_i - (Time.current.to_i % 30)) }
  let(:window) { Monitoring::Window.new("15m", now: now + 15.seconds) } # the current bucket half gone
  let(:earlier) { now - 30.seconds }

  let(:job_keys) { (1..).each }

  def run!(status, at:, total: nil, job_type: "pick")
    Monitoring::JobRun.create!(job_key: job_keys.next, activated_at: at, job_type: job_type, status: status,
                               total_duration_ms: total)
  end

  it "rates resolved jobs per minute by outcome in every bucket, quiet ones as zero" do
    run!("complete", at: earlier + 1.second)
    run!("complete", at: earlier + 2.seconds)
    run!("failed", at: earlier + 3.seconds)
    run!("handed_back", at: now)
    run!("ready", at: now)

    throughput = trends.throughput

    expect(throughput.keys).to eq(%w[complete failed error handed_back])
    expect(throughput["complete"]).to include(earlier => 4.0, now => 0.0)
    expect(throughput["failed"][earlier]).to eq(2.0)
    expect(throughput["handed_back"][now]).to eq(4.0) # one run in the 15 s so far
    expect(throughput["complete"].size).to eq(window.buckets.size)
  end

  it "takes exact p50 and p95 of total time per bucket over completed, failed and errored runs" do
    [10, 20, 30, 40, 1000].each { |ms| run!("complete", at: earlier + 1.second, total: ms) }
    run!("handed_back", at: earlier + 1.second, total: 99_999)

    expect(trends.latency["p50"].compact).to eq(earlier => 30.0)
    expect(trends.latency["p95"].compact).to eq(earlier => 808.0)
  end

  it "leaves a bucket with no resolved runs empty, so the line breaks there instead of dipping to zero" do
    run!("complete", at: earlier, total: 10)
    run!("ready", at: now)

    expect(trends.latency["p95"].keys).to eq(window.buckets)
    expect(trends.latency["p95"][now]).to be_nil
    expect(trends.failure_rate.keys).to eq(window.buckets)
    expect(trends.failure_rate.values_at(earlier, now)).to eq([0.0, nil])
  end

  it "rates failures against completed, failed and errored runs, BPMN errors not counted as failures" do
    run!("complete", at: earlier)
    run!("failed", at: earlier)
    run!("error", at: earlier)
    run!("failed", at: earlier)
    run!("handed_back", at: earlier)

    expect(trends.failure_rate[earlier]).to eq(50.0)
  end

  it "leaves out runs activated before the range" do
    run!("complete", at: now - 20.minutes, total: 5)

    expect(trends.latency.values.flat_map { |series| series.values.compact }).to be_empty
    expect(trends.throughput["complete"].values.sum).to eq(0)
  end
end
