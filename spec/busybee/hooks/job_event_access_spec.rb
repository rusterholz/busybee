# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/hooks/job_event_access"

RSpec.describe Busybee::Hooks::JobEventAccess do
  def build_event(data = {})
    ActiveSupport::HashWithIndifferentAccess.new(data).extend(described_class)
  end

  describe "status predicates" do
    it "completed? returns true when status is :complete" do
      expect(build_event(status: :complete)).to be_completed
    end

    it "completed? returns false for other statuses" do
      expect(build_event(status: :ready)).not_to be_completed
      expect(build_event(status: :failed)).not_to be_completed
    end

    it "failed? returns true when status is :failed" do
      expect(build_event(status: :failed)).to be_failed
    end

    it "failed? returns false for other statuses" do
      expect(build_event(status: :complete)).not_to be_failed
    end

    it "error? returns true when status is :error" do
      expect(build_event(status: :error)).to be_error
    end

    it "error? returns false for other statuses" do
      expect(build_event(status: :ready)).not_to be_error
    end

    it "errored? is an alias for error?" do
      event = build_event(status: :error)
      expect(event.errored?).to eq(event.error?)
    end
  end

  describe "computed durations" do
    let(:base) { 1000.0 }

    let(:full_event) do
      build_event(
        activated_at: base,
        execution_started_at: base + 0.5,
        perform_started_at: base + 0.8,
        perform_finished_at: base + 1.3,
        resolved_at: base + 1.4,
        executed_at: base + 1.6
      )
    end

    it "perform_duration_ms computes perform_finished_at - perform_started_at" do
      expect(full_event.perform_duration_ms).to eq(500.0)
    end

    it "resolution_duration_ms computes resolved_at - execution_started_at" do
      expect(full_event.resolution_duration_ms).to eq(900.0)
    end

    it "execution_duration_ms computes executed_at - execution_started_at" do
      expect(full_event.execution_duration_ms).to eq(1100.0)
    end

    it "buffer_latency_ms computes execution_started_at - activated_at" do
      expect(full_event.buffer_latency_ms).to eq(500.0)
    end

    it "total_duration_ms computes resolved_at - activated_at" do
      expect(full_event.total_duration_ms).to eq(1400.0)
    end

    it "post_resolution_ms computes executed_at - resolved_at" do
      expect(full_event.post_resolution_ms).to eq(200.0)
    end

    it "setup_duration_ms computes perform_started_at - execution_started_at" do
      expect(full_event.setup_duration_ms).to eq(300.0)
    end

    it "returns nil when timestamps are missing" do
      event = build_event(status: :ready)
      expect(event.perform_duration_ms).to be_nil
      expect(event.buffer_latency_ms).to be_nil
      expect(event.total_duration_ms).to be_nil
    end
  end

  describe "#tags" do
    let(:full_tag_event) do
      build_event(
        job_type: "process_order", worker_class: String, status: :complete,
        bpmn_process_id: "order-flow", job_key: 12_345, process_instance_key: 67_890, error: nil
      )
    end

    it "returns a hash of low-cardinality keys" do
      expect(full_tag_event.tags).to eq(
        "job_type" => "process_order",
        "worker_class" => String,
        "status" => :complete,
        "bpmn_process_id" => "order-flow"
      )
    end

    it "excludes high-cardinality keys" do
      event = build_event(
        job_type: "test",
        worker_class: Object,
        status: :ready,
        bpmn_process_id: "flow",
        job_key: 999,
        error: RuntimeError.new("boom")
      )

      expect(event.tags).not_to have_key("job_key")
      expect(event.tags).not_to have_key("error")
    end

    it "omits tag keys that are nil" do
      event = build_event(status: :ready)
      expect(event.tags).to eq("status" => :ready)
    end
  end

  describe "#error_message (inherited from EventAccess)" do
    it "returns error_message when present" do
      expect(build_event(error_message: "broke").error_message).to eq("broke")
    end

    it "falls back to error.message" do
      expect(build_event(error: RuntimeError.new("boom")).error_message).to eq("boom")
    end
  end
end
