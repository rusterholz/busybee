# frozen_string_literal: true

require "busybee/hooks"

RSpec.describe Busybee::Hooks do
  describe ".build_event" do
    subject(:event) { described_class.build_event(:job, data) }

    let(:data) do
      {
        job_type: "process_order",
        worker_class: String,
        status: :complete,
        bpmn_process_id: "order-flow",
        job_key: 12_345,
        activated_at: 1000.0,
        execution_started_at: 1000.5,
        perform_started_at: 1000.8,
        perform_finished_at: 1001.3,
        resolved_at: 1001.4,
        executed_at: 1001.6
      }
    end

    it "returns a HashWithIndifferentAccess" do
      expect(event).to be_a(ActiveSupport::HashWithIndifferentAccess)
    end

    it "supports method-style access via HashAccess" do
      expect(event.job_type).to eq("process_order")
      expect(event.job_key).to eq(12_345)
    end

    it "restricts framework keys from modification" do
      expect { event[:status] = :failed }.to raise_error(FrozenError)
    end

    it "allows annotations on new keys" do
      event[:trace_id] = "abc-123"
      expect(event[:trace_id]).to eq("abc-123")
    end

    it "provides noun-specific predicates" do
      expect(event).to be_completed
      expect(event).not_to be_failed
    end

    it "provides computed durations" do
      expect(event.perform_duration_ms).to eq(500.0)
      expect(event.buffer_latency_ms).to eq(500.0)
    end

    it "provides tags" do
      expect(event.tags).to include("job_type" => "process_order", "status" => :complete)
    end

    it "provides error_message" do
      err_event = described_class.build_event(:job, status: :failed, error: RuntimeError.new("boom"))
      expect(err_event.error_message).to eq("boom")
    end

    it "raises for unknown noun" do
      expect { described_class.build_event(:unknown, {}) }.to raise_error(ArgumentError, /unknown/)
    end

    it "accepts :worker noun" do
      event = described_class.build_event(:worker, worker_class: String, job_type: "test")
      expect(event.error_message).to be_nil
    end

    it "accepts :call noun" do
      event = described_class.build_event(:call, method: :complete_job)
      expect(event.error_message).to be_nil
    end
  end
end
