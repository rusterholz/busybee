# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe "Infrastructure queries" do # rubocop:disable RSpec/DescribeClass
  let(:now) { Time.zone.at(Time.current.to_i - (Time.current.to_i % 30)) + 15.seconds }
  let(:window) { Monitoring::Window.new("15m", now: now) }
  let(:bucket) { now - 15.seconds }

  def call!(rpc, network_ms: 10.0, at: bucket + 1.second, **attrs)
    Monitoring::EngineCall.create!(rpc: rpc, status: "succeeded", network_ms: network_ms, seq: 1.0, at: at, **attrs)
  end

  describe Monitoring::NetworkStats do
    subject(:stats) { described_class.new(Monitoring::EngineCall.all, window) }

    it "summarizes each rpc's network time, attempts and backoff, leaving out the long-poll fetches" do
      [10, 20, 30, 40, 1000].each { |ms| call!("complete_job", network_ms: ms) }
      call!("complete_job", network_ms: 5, attempts: 3, backoff_ms: 500.0)
      call!("activate_jobs", network_ms: 30_000)
      call!("stream_activated_jobs", network_ms: 60_000)
      call!("complete_job", network_ms: 9_999, at: now - 1.hour)

      expect(stats.rows).to eq([{ rpc: "complete_job", calls: 6, p50_ms: 25.0, p95_ms: 760.0,
                                  retried: 1, max_attempts: 3, backoff_ms: 500.0 }])
    end

    it "charts p95 per rpc in every bucket, empty where the rpc made no call" do
      call!("complete_job", network_ms: 12)
      call!("fail_job", network_ms: 8, at: bucket - 5.minutes)

      series = stats.p95_series

      expect(series.keys).to eq(%w[complete_job fail_job])
      expect(series["complete_job"].keys).to eq(window.buckets)
      expect(series["complete_job"].values_at(bucket, bucket - 5.minutes)).to eq([12.0, nil])
    end
  end

  describe Monitoring::Errors do
    subject(:errors) { described_class.new(Monitoring::EngineCall.all, Monitoring::WorkerProcess.all, window) }

    def errored!(rpc, error_class, **attrs)
      call!(rpc, status: "errored", error_class: error_class, error_message: "#{error_class} on #{rpc}", **attrs)
    end

    it "counts errored calls by class, rpc, job type and worker class, most frequent first" do
      2.times { errored!("complete_job", "Busybee::GRPC::Error", job_type: "pick", worker_class: "PickWorker") }
      errored!("publish_message", "Busybee::GRPC::Error", job_type: "ship", worker_class: "ShipWorker")
      call!("complete_job", job_type: "pick")

      expect(errors.calls.map { |row| row.values_at(:error_class, :rpc, :job_type, :worker_class, :count) }).
        to eq([["Busybee::GRPC::Error", "complete_job", "pick", "PickWorker", 2],
               ["Busybee::GRPC::Error", "publish_message", "ship", "ShipWorker", 1]])
      expect(errors.calls.first[:sample_message]).to eq("Busybee::GRPC::Error on complete_job")
    end

    it "rates errored calls per minute in every bucket, zero where there were none" do
      errored!("complete_job", "Busybee::GRPC::Error")

      per_minute = errors.calls_per_minute

      expect(per_minute.keys).to eq(window.buckets)
      expect(per_minute.values_at(bucket, bucket - 5.minutes)).to eq([4.0, 0.0])
    end

    it "lists the worker stops that carried an error within the range" do
      Monitoring::WorkerProcess.create!(worker_name: "w1", job_type: "pick", worker_class: "PickWorker",
                                        status: "shutdown", reason: "unhealthy", error_class: "Sim::Rollover",
                                        error_message: "rolling over w1", shutdown_at: now - 1.minute)
      Monitoring::WorkerProcess.create!(worker_name: "w2", job_type: "pick", status: "shutdown",
                                        shutdown_at: now - 1.minute)

      expect(errors.worker_stops.map { |row| row.values_at(:error_class, :worker_class, :reason, :count) }).
        to eq([["Sim::Rollover", "PickWorker", "unhealthy", 1]])
    end
  end
end
