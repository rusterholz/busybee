# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::CalculateDistanceWorker do
  let(:coords) { { from_lat: 0.0, from_lon: 0.0, to_lat: 3.0, to_lon: 4.0 } }

  it "computes pythagorean distance rounded to 2 places" do
    result = execute_worker(described_class, variables: coords, headers: { algorithm: "pythagorean" })
    expect(result).to eq(distance: 5.0)
  end

  it "fails the job on an unsupported algorithm" do
    job = build_worker_job(variables: coords, headers: { algorithm: "haversine" })
    described_class.perform_job(job)
    expect(job).to be_failed
  end
end
