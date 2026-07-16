# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Liveness do
  def worker(status:, depth:, name: SecureRandom.hex(4))
    Monitoring::WorkerProcess.create!(worker_name: name, job_type: "update_order_status",
                                      status: status, write_queue_depth: depth)
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

  describe "freshness" do
    it "measures seconds since the most recent worker write" do
      worker(status: "running", depth: 1)
      expect(described_class.new.freshness_s).to be_within(5).of(0)
    end

    it "is nil when there are no workers at all" do
      expect(described_class.new.freshness_s).to be_nil
    end
  end
end
