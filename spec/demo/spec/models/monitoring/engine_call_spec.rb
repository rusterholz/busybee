# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::EngineCall, :busybee do
  # EngineCall consumes a Call's high-cardinality projection, so the projection is
  # the contract under test — authoring it here by hand would assert our belief
  # about it rather than the thing itself. These are real Calls, driven through
  # the same underscore seam the client drives them through.

  let(:client) { build_test_client }

  # A job carries the runner's Worker::Status, and that is where a call gets its
  # worker_name from — a job-correlated call has one only because its job does.
  def job(key)
    build_test_job(key: key, type: "update_order_status", bpmn_process_id: "ship-order",
                   client: client, worker_class: Oms::UpdateOrderStatusWorker,
                   worker_status: build_test_worker_status(worker_class: Oms::UpdateOrderStatusWorker,
                                                           worker_mode: :hybrid))
  end

  # `attempted: false` leaves the call with no observed network time — the "never
  # got off the ground" shape.
  def call(rpc, **attrs) = build_test_call(rpc, **attrs)

  describe ".record" do
    it "persists a job-correlated call from its logging_context" do
      recorded = call(:complete_job, job: job(476))

      described_class.record(recorded, seq: 1.0)

      expect(described_class.for_job(476).sole).to have_attributes(
        worker_name: Busybee.worker_name, rpc: "complete_job", status: "succeeded",
        network_ms: recorded.network_ms, error_class: nil
      )
    end

    it "ignores a fetch/poll call with no job in scope" do
      described_class.record(call(:activate_jobs), seq: 1.0)

      expect(described_class.count).to eq(0)
    end

    it "ignores a call with no observed network time" do
      described_class.record(call(:complete_job, job: job(476), attempted: false), seq: 1.0)

      expect(described_class.count).to eq(0)
    end
  end

  describe ".for_job" do
    it "returns one job's calls in observation order" do
      described_class.record(call(:publish_message, job: job(476)), seq: 2.0)
      described_class.record(call(:complete_job, job: job(476)), seq: 3.0)
      described_class.record(call(:activate_jobs, job: job(476)), seq: 1.0)
      described_class.record(call(:complete_job, job: job(999)), seq: 4.0)

      expect(described_class.for_job(476).pluck(:rpc)).to eq(%w[activate_jobs publish_message complete_job])
    end
  end
end
