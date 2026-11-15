# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::JobTypeSummary do
  let(:now) { Time.current }
  let(:window) { Monitoring::Window.new("15m", now: now) }

  let(:job_keys) { (1..).each }

  def run!(job_type, status, total: nil, at: now - 1.minute)
    Monitoring::JobRun.create!(job_key: job_keys.next, activated_at: at, job_type: job_type, status: status,
                               total_duration_ms: total)
  end

  it "summarizes each job type over the range, busiest first" do
    4.times { |i| run!("pick", "complete", total: (i + 1) * 10) }
    run!("pick", "failed", total: 500)
    run!("pick", "ready")
    run!("ship", "error", total: 7)
    run!("ship", "complete", total: 3)
    run!("ship", "complete", total: 1, at: now - 1.hour)

    rows = described_class.new(Monitoring::JobRun.all, window).rows

    expect(rows.map { |row| row[:job_type] }).to eq(%w[pick ship])
    expect(rows.first).to eq(job_type: "pick", jobs: 6, per_minute: 0.4, p50_ms: 30.0, p95_ms: 408.0,
                             failure_pct: 20.0, error_pct: 0.0)
    expect(rows.last).to include(jobs: 2, failure_pct: 0.0, error_pct: 50.0)
  end
end
