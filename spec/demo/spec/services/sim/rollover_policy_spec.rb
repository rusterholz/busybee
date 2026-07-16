# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::RolloverPolicy do
  def status(uptime) = instance_double(Busybee::Worker::Status, uptime_s: uptime)

  describe ".hazard" do
    it "rises with the worker's uptime" do
      expect(described_class.hazard(status(120), 1.0)).to be > described_class.hazard(status(0), 1.0)
    end

    it "scales linearly with simulation speed" do
      at_1 = described_class.hazard(status(0), 1.0)
      at_10 = described_class.hazard(status(0), 10.0)
      expect(at_10).to be_within(1e-9).of(at_1 * 10)
    end

    it "never exceeds certainty" do
      expect(described_class.hazard(status(1_000_000), 1000.0)).to eq(1.0)
    end
  end

  describe ".hazard_for" do
    it "uses the configured simulation speed (1.0 under test)" do
      expect(described_class.hazard_for(status(0))).to be_within(1e-9).of(0.02)
    end
  end

  describe ".roll?" do
    it "fires only when the draw falls under the hazard" do
      new_worker = status(0) # hazard 0.02 at speed 1.0
      expect(described_class.roll?(new_worker, speed: 1.0, random: 0.01)).to be(true)
      expect(described_class.roll?(new_worker, speed: 1.0, random: 0.99)).to be(false)
    end
  end
end
