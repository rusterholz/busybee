# frozen_string_literal: true

require "busybee/worker/status"

RSpec.describe Busybee::Worker::Status do
  let(:worker_class) do
    stub_const("StatusOrderWorker", Class.new(Busybee::Worker) do
      job_type "process_order"
      description "Processes an order"
      variable :order_id, type: "string"
      output :status, type: "string"
    end)
  end

  let(:timestamps) { Busybee::Worker::Timestamps.new }

  def build_status(**overrides)
    described_class.new(worker_class: worker_class, worker_mode: :polling,
                        timestamps: timestamps, **overrides)
  end

  describe "identity" do
    it "exposes the worker class" do
      expect(build_status.worker_class).to be(worker_class)
    end

    it "exposes the worker class's configuration" do
      expect(build_status.configuration).to be(worker_class.configuration)
    end

    it "delegates the declared DSL contract to the configuration" do
      status = build_status
      expect(status.job_type).to eq("process_order")
      expect(status.description).to eq("Processes an order")
      expect(status.inputs.map(&:name)).to eq(%i[order_id])
      expect(status.outputs.map(&:name)).to eq(%i[status])
    end

    it "exposes the resolved worker mode it was built with" do
      expect(build_status(worker_mode: :streaming).worker_mode).to eq(:streaming)
    end

    it "reports the process-wide worker name" do
      allow(Busybee).to receive(:worker_name).and_return("orders-pod-7")
      expect(build_status.worker_name).to eq("orders-pod-7")
    end
  end

  describe "outcome" do
    it "leaves reason/error nil until the run ends" do
      status = build_status
      expect(status.reason).to be_nil
      expect(status.error).to be_nil
      expect(status.error_class).to be_nil
      expect(status.error_message).to be_nil
    end

    it "reports a signal stop" do
      expect(build_status(reason: :signal).reason).to eq(:signal)
    end

    it "reports an errored stop with its class and message" do
      error = RuntimeError.new("boom")
      status = build_status(reason: :error, error: error)
      expect(status.reason).to eq(:error)
      expect(status.error).to be(error)
      expect(status.error_class).to eq(RuntimeError) # the Class, matching worker_class
      expect(status.error_message).to eq("boom")
    end
  end

  describe "counters" do
    it "default to zero" do
      status = build_status
      expect(status.total_job_count).to eq(0)
      expect(status.failed_job_count).to eq(0)
      expect(status.backpressure_count).to eq(0)
    end

    it "report the snapshotted values" do
      status = build_status(total_job_count: 42, failed_job_count: 3, backpressure_count: 7)
      expect(status.total_job_count).to eq(42)
      expect(status.failed_job_count).to eq(3)
      expect(status.backpressure_count).to eq(7)
    end
  end

  describe "buffer gauges" do
    it "are nil when not applicable (e.g. polling)" do
      status = build_status
      expect(status.current_buffer_size).to be_nil
      expect(status.peak_buffer_size).to be_nil
    end

    it "report the snapshotted depth and high-water mark" do
      status = build_status(current_buffer_size: 4, peak_buffer_size: 9)
      expect(status.current_buffer_size).to eq(4)
      expect(status.peak_buffer_size).to eq(9)
    end
  end

  describe "lifecycle timing" do
    it "delegates per-moment readers (with the kind arg) to the timestamps" do
      timestamps.stamp!(:started_at)
      status = build_status
      expect(status.started_at).to be_a(Time)
      expect(status.started_at(:monotonic)).to be_a(Float)
    end

    it "is nil for moments not yet stamped" do
      expect(build_status.shutdown_at).to be_nil
    end

    it "delegates the computed durations to the timestamps" do
      timestamps.stamp!(:stopping_at)
      sleep 0.001
      timestamps.stamp!(:shutdown_at)
      expect(build_status.stop_duration_ms).to be_a(Float).and(be > 0)
    end

    it "snapshots the timestamps, so later stamping does not mutate the status" do
      status = build_status
      timestamps.stamp!(:shutdown_at) # after the snapshot was taken
      expect(status.shutdown_at).to be_nil
    end
  end

  describe "#context_tags / #logging_context" do
    it "projects low-cardinality identity and outcome as tags (class and error class as names)" do
      status = build_status(reason: :error, error: RuntimeError.new("boom"))
      expect(status.context_tags).to include(
        worker_class: "StatusOrderWorker",
        job_type: "process_order",
        worker_mode: :polling,
        reason: :error,
        error_class: "RuntimeError"
      )
    end

    it "omits nil tags (no reason/error class on a clean, mid-run status)" do
      tags = build_status.context_tags
      aggregate_failures do
        expect(tags).not_to have_key(:reason)
        expect(tags).not_to have_key(:error_class)
      end
    end

    it "is a superset in logging_context, adding timings, counters, gauges, and error message" do
      timestamps.stamp!(:started_at)
      status = build_status(reason: :error, error: RuntimeError.new("boom"),
                            total_job_count: 3, failed_job_count: 1, backpressure_count: 2,
                            current_buffer_size: 5, peak_buffer_size: 9)
      log = status.logging_context
      aggregate_failures do
        expect(log).to include(status.context_tags)
        expect(log).to include(total_job_count: 3, failed_job_count: 1, backpressure_count: 2)
        expect(log).to include(current_buffer_size: 5, peak_buffer_size: 9)
        expect(log).to include(error_message: "boom", started_at: status.started_at)
        expect(log[:uptime_s]).to be_a(Float)
      end
    end

    it "keeps high-cardinality dimensions out of the tags" do
      timestamps.stamp!(:started_at)
      tags = build_status(total_job_count: 3, current_buffer_size: 5).context_tags
      aggregate_failures do
        expect(tags).not_to have_key(:started_at)
        expect(tags).not_to have_key(:total_job_count)
        expect(tags).not_to have_key(:current_buffer_size)
      end
    end
  end

  describe "immutability" do
    it "is frozen" do
      expect(build_status).to be_frozen
    end
  end
end
