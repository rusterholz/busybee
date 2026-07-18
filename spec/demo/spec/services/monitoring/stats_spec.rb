# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Stats do
  subject(:stats) { described_class.new(Monitoring::JobRun.all) }

  def create_run(**attrs)
    defaults = { job_key: next_job_key, job_type: "assign_driver", status: "complete" }
    Monitoring::JobRun.create!(defaults.merge(attrs))
  end

  def next_job_key
    (Monitoring::JobRun.maximum(:job_key) || 0) + 1
  end

  describe "#total_count" do
    it "counts every run in scope" do
      3.times { create_run }
      expect(stats.total_count).to eq(3)
    end
  end

  describe "#counts_by_status" do
    it "returns all four statuses, zero-filled" do
      create_run(status: "complete")
      create_run(status: "failed")

      expect(stats.counts_by_status).to eq("ready" => 0, "complete" => 1, "failed" => 1, "error" => 0)
    end
  end

  describe "duration stats" do
    it "computes mean/max over resolved rows only, ignoring ready (async-dispatch) rows" do
      create_run(status: "complete", perform_duration_ms: 100, total_duration_ms: 200)
      create_run(status: "complete", perform_duration_ms: 300, total_duration_ms: 600)
      # An async worker recorded at dispatch: still :ready, ~0 perform. Must not drag the means.
      create_run(status: "ready", perform_duration_ms: 0, total_duration_ms: nil)

      expect(stats.mean_perform_ms).to eq(200)
      expect(stats.max_perform_ms).to eq(300)
      expect(stats.max_total_ms).to eq(600)
    end
  end

  describe "#max_buffer_depth" do
    it "returns the deepest buffer seen across the scope" do
      create_run(buffer_size: 2)
      create_run(buffer_size: 7)
      create_run(buffer_size: nil)

      expect(stats.max_buffer_depth).to eq(7)
    end
  end

  describe "#by_job_type" do
    it "breaks totals, outcomes and typical duration down per type, busiest first" do
      create_run(job_type: "assign_driver", status: "complete", total_duration_ms: 100)
      create_run(job_type: "assign_driver", status: "failed", total_duration_ms: 200)
      create_run(job_type: "create_shipment", status: "complete", total_duration_ms: 50)

      rows = stats.by_job_type
      expect(rows.map { |r| r[:job_type] }).to eq(%w[assign_driver create_shipment])
      expect(rows.first).to include(job_type: "assign_driver", total: 2, complete: 1, failed: 1, error: 0)
      expect(rows.first[:mean_total_ms]).to eq(150.0)
    end
  end
end
