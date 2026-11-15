# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::GuardedUpsert do
  let(:identity) { { job_key: 1, activated_at: Time.utc(2026, 1, 1) } }
  let(:long_ago) { Time.utc(2020, 1, 1) }
  let(:row) { Monitoring::JobRun.find_by!(job_key: 1) }

  def write(seen_at:, **attributes)
    described_class.call(Monitoring::JobRun, identity, rank: 1, seen_at: seen_at,
                                                       attributes: { job_type: "pick", status: "ready", **attributes })
  end

  before do
    write(seen_at: 10, error_message: nil)
    row.update_column(:updated_at, long_ago)
  end

  it "moves updated_at when a write ahead of the row takes over" do
    write(seen_at: 20, status: "complete")

    expect(row.reload).to have_attributes(status: "complete")
    expect(row.updated_at).to be > long_ago
  end

  it "moves updated_at when a write behind the row fills a gap in it" do
    write(seen_at: 5, error_message: "late detail")

    expect(row.reload).to have_attributes(error_message: "late detail", seen_at: 10)
    expect(row.updated_at).to be > long_ago
  end

  it "leaves updated_at alone when a write behind the row has nothing to add" do
    write(seen_at: 5, status: "failed")

    expect(row.reload).to have_attributes(status: "ready")
    expect(row.updated_at).to eq(long_ago)
  end
end
