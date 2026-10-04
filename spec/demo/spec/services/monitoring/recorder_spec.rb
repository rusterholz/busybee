# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Recorder do
  # Carriers come from the gem's own builders, which build them the way production
  # does. What stays here is this spec's parameterisation — the Oms worker and its
  # job type — not the mechanics.

  let(:client) { build_test_client }

  # worker_name is a live delegate to Busybee.worker_name, not a Status field —
  # so the row's identity is the ambient container name, and no builder can pin it.
  def process = Monitoring::WorkerProcess.find_by(worker_name: Busybee.worker_name, job_type: "update_order_status")

  def recorded(job_key) = Monitoring::JobRun.find_by(job_key: job_key)

  def activated_job(key:, **attrs)
    build_test_job(key: key, type: "update_order_status", bpmn_process_id: "ship-order",
                   client: client, worker_class: Oms::UpdateOrderStatusWorker, **attrs)
  end

  # A job that really reached :complete, through Job#complete! and the wire.
  def completed_job(key:, **attrs)
    activated_job(key: key, **attrs).tap do |job|
      job.timestamps.stamp!(:execution_started_at)
      without_busybee_hooks(:all) { job.complete!({}) }
      job.timestamps.stamp!(:executed_at)
    end
  end

  def resolved_call(rpc, request = nil, **attrs) = build_test_call(rpc, request: request, **attrs)

  # The gem's builder takes the worker class; this spec's subject is always the
  # Oms worker, so name that once here rather than at every call site.
  def worker_status(**attrs)
    build_test_worker_status(worker_class: Oms::UpdateOrderStatusWorker, worker_mode: :hybrid, **attrs)
  end

  def complete_request(job_key) = Busybee::GRPC::CompleteJobRequest.new(jobKey: job_key)

  describe ".record_activation" do
    it "records buffer depth from the worker status and whether the job was buffered" do
      job = activated_job(key: 4242, worker_status: worker_status(current_buffer_size: 4), buffered: true)

      described_class.record_activation(job)

      expect(recorded(4242)).to have_attributes(buffer_size: 4, buffered: true)
    end

    it "is nil-safe when no worker status is attached" do
      job = activated_job(key: 4243)

      described_class.record_activation(job)

      expect(recorded(4243)).to have_attributes(buffer_size: nil, buffered: false)
    end
  end

  describe ".record_worker" do
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

    it "records the lifecycle timestamps the status snapshotted" do
      described_class.record_worker(:stopping,
                                    worker_status(moments: %i[started_at stop_requested_at stopping_at]))

      expect(process).to have_attributes(started_at: be_present, stop_requested_at: be_present,
                                         stopping_at: be_present, shutdown_at: nil)
    end

    it "scalarizes the status's error for storage" do
      described_class.record_worker(:shutdown, worker_status(reason: :unhealthy,
                                                             error: Sim::Rollover.new("rolling over")))

      expect(process).to have_attributes(reason: "unhealthy", error_class: "Sim::Rollover",
                                         error_message: "rolling over")
    end

    it "captures the recorder's write-queue backlog as a liveness gauge" do
      allow(described_class).to receive(:queue_depth).and_return(5)

      described_class.record_worker(:running, worker_status)

      expect(process.write_queue_depth).to eq(5)
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
      executed = completed_job(key: 7777)
      activated = activated_job(key: 7777)

      described_class.record_execution(executed)   # rank 1
      described_class.record_activation(activated) # rank 0 — arrives late

      expect(recorded(7777)).to have_attributes(status: "complete", activated_at: be_present)
    end
  end

  describe ".record_handback" do
    # The other closer. Without it, a job the worker had in hand when a deploy
    # landed leaves its row stuck at rank 0 forever — the leak the pairing exists
    # to prevent, and the reason the demo wires all three hooks rather than two.
    it "closes an activation the worker never got to run" do
      activated = activated_job(key: 8888)
      described_class.record_activation(activated)

      handed_back = activated_job(key: 8888)
      sleep 0.005
      handed_back.timestamps.stamp!(:execution_started_at) # the moment it was handed back, not run

      described_class.record_handback(handed_back)

      expect(recorded(8888)).to have_attributes(status: "ready", executed_at: be_present, lifecycle_rank: 1,
                                                buffer_latency_ms: handed_back.buffer_latency_ms)
      expect(handed_back.buffer_latency_ms).to be > 0
    end

    # A handback whose own call failed is the worker's error, not the job's — the
    # job was never attempted and reports nothing of its own.
    it "records a failed handback's error off the worker carrier" do
      status = worker_status(error: StandardError.new("broker unreachable"))
      handed_back = activated_job(key: 8889, worker_status: status)

      described_class.record_handback(handed_back)

      expect(recorded(8889)).to have_attributes(error_message: "broker unreachable", status: "ready")
    end
  end

  describe ".record_call" do
    it "folds a resolved call's duration into the engine_call metric under its tags" do
      # A fetch call: no job in scope, so it carries worker identity and no job keys.
      call = resolved_call(:activate_jobs, worker_status: worker_status)

      described_class.record_call(call)

      metric = Monitoring::CallMetric.find_by(metric_name: "engine_call")
      expect(metric).to have_attributes(count: 1, ewma: call.network_ms)
      expect(call.network_ms).to be > 0
      expect(metric.tags).to include("rpc" => "activate_jobs", "status" => "succeeded", "grpc_status" => "ok",
                                     "worker_class" => "Oms::UpdateOrderStatusWorker",
                                     "job_type" => "update_order_status", "worker_mode" => "hybrid")
      expect(metric.tags.keys).not_to include("job_key", "bpmn_process_id")
      expect(Monitoring::EngineCall.count).to eq(0) # a fetch call is aggregate-only
    end

    it "also records a job-correlated call as an EngineCall row (the per-job log twin)" do
      job = activated_job(key: 476, worker_status: worker_status)
      call = resolved_call(:complete_job, complete_request(476), job: job)

      described_class.record_call(call)

      expect(Monitoring::EngineCall.for_job(476).sole).to have_attributes(
        rpc: "complete_job", worker_name: Busybee.worker_name,
        network_ms: call.network_ms, status: "succeeded"
      )
    end

    it "ignores a call with no observed network time" do
      call = Busybee::Client::Call.new(:complete_job, complete_request(477)) # never attempted

      described_class.record_call(call)

      expect(Monitoring::CallMetric.count).to eq(0)
      expect(Monitoring::EngineCall.count).to eq(0)
    end

    it "folds an async resolution's outcome back into its JobRun" do
      # An async worker resolves after perform returned: record_execution saw the
      # run still ready, and the resolution RPC is the only lifecycle signal left.
      job = activated_job(key: 600)
      job.timestamps.stamp!(:executed_at)
      described_class.record_execution(job)

      described_class.record_call(resolved_call(:complete_job, complete_request(600), job: job))

      expect(recorded(600).status).to eq("complete")
    end

    it "maps fail_job and throw_error to their run outcomes" do
      jobs = [601, 602].to_h do |key|
        job = activated_job(key: key)
        job.timestamps.stamp!(:executed_at)
        described_class.record_execution(job)
        [key, job]
      end

      described_class.record_call(resolved_call(:fail_job, job: jobs[601]))
      described_class.record_call(resolved_call(:throw_error, job: jobs[602]))

      expect(recorded(601).status).to eq("failed")
      expect(recorded(602).status).to eq("error")
    end

    it "does not mark a run resolved when the resolution RPC itself errored" do
      job = activated_job(key: 603)
      job.timestamps.stamp!(:executed_at)
      described_class.record_execution(job)

      described_class.record_call(resolved_call(:complete_job, complete_request(603), job: job, status: :errored))

      expect(recorded(603).status).to eq("ready")
    end
  end

  # The drain semantics need the real background executor, not the file-wide
  # immediate stub — the unit under test is the wait across the writer thread.
  describe ".shutdown!" do
    before { allow(described_class).to receive(:executor).and_call_original }

    after do
      described_class.instance_variable_get(:@executor)&.kill
      described_class.instance_variable_set(:@executor, nil)
    end

    it "waits for queued writes before returning" do
      flag = Concurrent::AtomicBoolean.new(false)
      described_class.executor.post do
        sleep 0.05
        flag.make_true
      end

      described_class.shutdown!

      expect(flag).to be_true
    end

    it "quietly discards writes arriving after shutdown" do
      described_class.executor
      described_class.shutdown!

      expect { described_class.executor.post { nil } }.not_to raise_error
    end

    it "does not create an executor when none was ever needed" do
      described_class.shutdown!

      expect(described_class.instance_variable_get(:@executor)).to be_nil
    end
  end

  describe ".flush" do
    before { allow(described_class).to receive(:executor).and_call_original }

    after do
      described_class.instance_variable_get(:@executor)&.kill
      described_class.instance_variable_set(:@executor, nil)
    end

    it "returns true after queued writes complete, leaving the executor accepting" do
      flag = Concurrent::AtomicBoolean.new(false)
      described_class.executor.post do
        sleep 0.05
        flag.make_true
      end

      expect(described_class.flush).to be(true)
      expect(flag).to be_true
      expect(described_class.executor).not_to be_shutdown
    end

    it "returns false when the queue cannot drain in time" do
      described_class.executor.post { sleep 0.3 }

      expect(described_class.flush(timeout: 0.05)).to be(false)
    end
  end
end
