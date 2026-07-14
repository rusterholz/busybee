# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::EngineCall do
  # A call double carrying only its high-cardinality projection — the one input
  # EngineCall consumes (the log/trace twin of CallMetric's context_tags).
  def call(**logging_context)
    instance_double(Busybee::Client::Call, logging_context: logging_context)
  end

  describe ".record" do
    it "persists a job-correlated call from its logging_context" do
      described_class.record(
        call(job_key: 476, worker_name: "oms-worker-ab12", rpc: "complete_job",
             status: :succeeded, network_ms: 117.0, error_class: nil),
        seq: 1.0
      )

      expect(described_class.for_job(476).sole).to have_attributes(
        worker_name: "oms-worker-ab12", rpc: "complete_job", status: "succeeded",
        network_ms: 117.0
      )
    end

    it "ignores a fetch/poll call with no job in scope" do
      described_class.record(call(rpc: "activate_jobs", network_ms: 68.0), seq: 1.0)

      expect(described_class.count).to eq(0)
    end

    it "ignores a call with no observed network time" do
      described_class.record(call(job_key: 476, rpc: "complete_job"), seq: 1.0)

      expect(described_class.count).to eq(0)
    end
  end

  describe ".for_job" do
    it "returns one job's calls in observation order" do
      described_class.record(call(job_key: 476, rpc: "publish_message", network_ms: 79.0), seq: 2.0)
      described_class.record(call(job_key: 476, rpc: "complete_job", network_ms: 117.0), seq: 3.0)
      described_class.record(call(job_key: 476, rpc: "activate_jobs", network_ms: 68.0), seq: 1.0)
      described_class.record(call(job_key: 999, rpc: "complete_job", network_ms: 5.0), seq: 4.0)

      expect(described_class.for_job(476).pluck(:rpc)).to eq(%w[activate_jobs publish_message complete_job])
    end
  end
end
