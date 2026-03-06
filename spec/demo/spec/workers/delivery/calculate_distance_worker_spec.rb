# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::CalculateDistanceWorker do
  let(:coords) { { from_lat: 0.0, from_lon: 0.0, to_lat: 3.0, to_lon: 4.0 } }
  let(:headers) { { algorithm: algorithm } }
  let(:job) { build_test_job(variables: coords, headers: headers) }

  context "with a supported algorithm" do
    let(:algorithm) { "pythagorean" }

    it "computes distance rounded to 2 places and completes the job" do
      expect(described_class).to complete_job(job).
        with_vars(hash_including(distance: 5.0))
    end
  end

  context "with an unsupported algorithm" do
    let(:algorithm) { "haversine" }

    it "fails the job" do
      expect(described_class).to fail_job(job).
        with_error(RuntimeError, /Unknown distance algorithm/)
    end
  end
end
