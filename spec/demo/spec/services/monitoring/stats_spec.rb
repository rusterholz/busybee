# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Stats do
  subject(:stats) { described_class.new(Monitoring::JobRun.all) }

  def create_run(**attrs)
    defaults = { job_key: next_job_key, activated_at: Time.current, job_type: "assign_driver", status: "complete" }
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
    it "returns every status, handed_back included, zero-filled" do
      create_run(status: "complete")
      create_run(status: "failed")
      create_run(status: "handed_back")

      expect(stats.counts_by_status).
        to eq("ready" => 0, "complete" => 1, "failed" => 1, "error" => 0, "handed_back" => 1)
    end
  end
end
