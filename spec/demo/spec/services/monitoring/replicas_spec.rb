# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Replicas do
  let(:now) { Time.current.change(usec: 0) }

  def incarnation(job_type, started:, shutdown: nil)
    Monitoring::WorkerProcess.create!(worker_name: SecureRandom.hex(4), job_type: job_type,
                                      status: shutdown ? "shutdown" : "running",
                                      started_at: started, shutdown_at: shutdown)
  end

  it "counts, per job type at each instant, the incarnations started and not yet shut down" do
    incarnation("pick", started: now - 10.minutes)
    incarnation("pick", started: now - 10.minutes, shutdown: now - 5.minutes)
    incarnation("pick", started: now - 4.minutes)
    incarnation("ship", started: now - 1.minute)

    series = described_class.new(from: now - 9.minutes, to: now, step: 3.minutes).series

    expect(series).to eq(
      "pick" => { now - 9.minutes => 2, now - 6.minutes => 2, now - 3.minutes => 2, now => 2 },
      "ship" => { now - 9.minutes => 0, now - 6.minutes => 0, now - 3.minutes => 0, now => 1 }
    )
  end

  it "keeps counting an incarnation that never recorded a shutdown" do
    incarnation("pick", started: now - 2.days)

    expect(described_class.new(from: now, to: now, step: 1.minute).series).to eq("pick" => { now => 1 })
  end
end
