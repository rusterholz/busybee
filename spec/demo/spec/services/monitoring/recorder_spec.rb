# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Recorder do
  # Run the background write inline so we can assert on the persisted row within
  # the example's transaction (the real executor writes on another thread/connection).
  before do
    allow(described_class).to receive(:executor).and_return(Concurrent::ImmediateExecutor.new)
  end

  def recorded(job_key) = Monitoring::JobRun.find_by(job_key: job_key)

  describe ".record_activation" do
    it "records buffer depth from the worker status and whether the job was buffered" do
      status = instance_double(Busybee::Worker::Status, current_buffer_size: 4)
      job = build_test_job(key: 4242)
      allow(job).to receive_messages(worker_status: status, buffered?: true)

      described_class.record_activation(job)

      expect(recorded(4242)).to have_attributes(buffer_size: 4, buffered: true)
    end

    it "is nil-safe when no worker status is attached" do
      job = build_test_job(key: 4243)
      allow(job).to receive_messages(worker_status: nil, buffered?: false)

      described_class.record_activation(job)

      expect(recorded(4243)).to have_attributes(buffer_size: nil, buffered: false)
    end
  end

  describe ".record_worker" do
    def worker_status(**overrides)
      defaults = {
        worker_name: "oms-worker-abc12", job_type: "update_order_status",
        worker_class: Oms::UpdateOrderStatusWorker, worker_mode: :hybrid,
        reason: nil, error_class: nil, error_message: nil,
        total_job_count: 0, failed_job_count: 0, backpressure_count: 0,
        current_buffer_size: nil, peak_buffer_size: nil,
        started_at: nil, stop_requested_at: nil, stopping_at: nil, shutdown_at: nil
      }
      instance_double(Busybee::Worker::Status, **defaults, **overrides)
    end

    def process = Monitoring::WorkerProcess.find_by(worker_name: "oms-worker-abc12", job_type: "update_order_status")

    it "records identity, phase, counters and gauges keyed by (worker_name, job_type)" do
      described_class.record_worker(:running, worker_status(
                                                total_job_count: 7, failed_job_count: 2, backpressure_count: 1,
                                                current_buffer_size: 3, peak_buffer_size: 9
                                              ))

      expect(process).to have_attributes(
        status: "running", worker_class: "Oms::UpdateOrderStatusWorker", worker_mode: "hybrid",
        total_job_count: 7, failed_job_count: 2, backpressure_count: 1,
        current_buffer_size: 3, peak_buffer_size: 9
      )
    end

    it "advances the same row through the lifecycle (upsert by identity, not a new row)" do
      described_class.record_worker(:running, worker_status)
      described_class.record_worker(:shutdown, worker_status(reason: :rollover))

      expect(Monitoring::WorkerProcess.count).to eq(1)
      expect(process).to have_attributes(status: "shutdown", reason: "rollover")
    end

    it "keeps a later phase when an earlier-phase write arrives out of order" do
      described_class.record_worker(:shutdown, worker_status(reason: :rollover))
      described_class.record_worker(:running, worker_status) # a stale 'running' landing late

      expect(process).to have_attributes(status: "shutdown", reason: "rollover")
    end

    it "keeps the freshest same-phase observation when a stale one is written last" do
      # Same rank (running); the second write is an OLDER observation (smaller
      # seen_at) whose write merely landed later — it must not overwrite.
      allow(described_class).to receive(:monotonic_seq).and_return(100.0, 50.0)

      described_class.record_worker(:running, worker_status(total_job_count: 7))
      described_class.record_worker(:running, worker_status(total_job_count: 5))

      expect(process.total_job_count).to eq(7)
    end

    it "is idempotent — a re-delivered observation neither duplicates nor regresses" do
      allow(described_class).to receive(:monotonic_seq).and_return(100.0)

      2.times { described_class.record_worker(:running, worker_status(total_job_count: 3)) }

      expect(Monitoring::WorkerProcess.count).to eq(1)
      expect(process.total_job_count).to eq(3)
    end
  end

  describe "out-of-order guard (JobRun)" do
    it "fills a late activation's gaps without downgrading a resolved status" do
      executed = build_test_job(key: 7777)
      allow(executed).to receive_messages(status: "complete", executed_at: Time.current)
      activated = build_test_job(key: 7777)
      allow(activated).to receive_messages(status: "ready", activated_at: Time.current,
                                           worker_status: nil, buffered?: false)

      described_class.record_execution(executed)   # rank 1
      described_class.record_activation(activated) # rank 0 — arrives late

      expect(recorded(7777)).to have_attributes(status: "complete", activated_at: be_present)
    end
  end
end
