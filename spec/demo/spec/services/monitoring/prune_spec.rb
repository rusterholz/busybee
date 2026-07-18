# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Prune do
  def worker!(name, touched_at)
    Monitoring::WorkerProcess.create!(worker_name: name, job_type: "t", status: "shutdown").
      tap { |w| w.update_column(:updated_at, touched_at) }
  end

  def run!(key, status, touched_at)
    Monitoring::JobRun.create!(job_key: key, job_type: "t", status: status).
      tap { |r| r.update_column(:updated_at, touched_at) }
  end

  it "drops workers and stuck-ready runs untouched past the horizon, keeping history" do
    worker!("w-stale", 11.minutes.ago)
    worker!("w-fresh", 1.minute.ago)
    run!(1, "ready", 11.minutes.ago)    # lost resolution — debris
    run!(2, "ready", 1.minute.ago)      # genuinely in flight
    run!(3, "complete", 11.minutes.ago) # resolved history — kept

    described_class.run

    expect(Monitoring::WorkerProcess.pluck(:worker_name)).to eq(["w-fresh"])
    expect(Monitoring::JobRun.order(:job_key).pluck(:job_key)).to eq([2, 3])
  end

  it "reports what it dropped" do
    worker!("w-stale", 11.minutes.ago)
    run!(1, "ready", 11.minutes.ago)

    expect(described_class.run).to eq(workers: 1, runs: 1)
  end
end
