# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Liveness do
  def worker(status:, depth: 0, name: SecureRandom.hex(4))
    Monitoring::WorkerProcess.create!(worker_name: name, job_type: "update_order_status",
                                      status: status, write_queue_depth: depth)
  end

  def call!(worker_name, at)
    Monitoring::EngineCall.create!(worker_name: worker_name, rpc: "complete_job", seq: 1.0, at: at)
  end

  describe "write-queue depth across running workers" do
    it "reports the max and mean depth, ignoring workers that have stopped" do
      worker(status: "running", depth: 2)
      worker(status: "running", depth: 8)
      worker(status: "shutdown", depth: 100) # a dead worker's stale backlog doesn't count

      liveness = described_class.new
      expect(liveness.max_queue_depth).to eq(8)
      expect(liveness.mean_queue_depth).to eq(5.0)
    end

    it "is nil when nothing is running" do
      worker(status: "shutdown", depth: 3)
      expect(described_class.new.max_queue_depth).to be_nil
    end
  end

  describe "#running_count" do
    it "counts workers whose last lifecycle event left them running, however long ago they last wrote" do
      worker(status: "running").update_column(:updated_at, 2.hours.ago)
      worker(status: "stopping")

      expect(described_class.new.running_count).to eq(1)
    end
  end

  describe "#last_call_at" do
    it "maps each worker to its most recent engine call" do
      call!("oms-worker-a", 3.minutes.ago)
      call!("oms-worker-a", 1.minute.ago)
      call!("oms-worker-b", 5.minutes.ago)

      last = described_class.new.last_call_at(%w[oms-worker-a oms-worker-c])

      expect(last.keys).to eq(["oms-worker-a"])
      expect(last["oms-worker-a"]).to be_within(1).of(1.minute.ago)
    end
  end
end
