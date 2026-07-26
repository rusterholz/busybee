# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::RolloverPolicy do
  def status(uptime) = instance_double(Busybee::Worker::Status, uptime_s: uptime)

  before { described_class.reset! }

  describe ".hazard" do
    it "rises with the worker's uptime" do
      expect(described_class.hazard(status(120), 1.0, 10.0)).
        to be > described_class.hazard(status(0), 1.0, 10.0)
    end

    it "scales linearly with simulation speed below the cap" do
      at_1 = described_class.hazard(status(0), 1.0, 10.0)
      at_3 = described_class.hazard(status(0), 3.0, 10.0)
      expect(at_3).to be_within(1e-9).of(at_1 * 3)
    end

    it "scales linearly with the elapsed slice" do
      short = described_class.hazard(status(0), 1.0, 10.0)
      long = described_class.hazard(status(0), 1.0, 30.0)
      expect(long).to be_within(1e-9).of(short * 3)
    end

    it "never exceeds certainty" do
      expect(described_class.hazard(status(1_000_000), 1000.0, 3600.0)).to eq(1.0)
    end

    it "depends only on sim-time (speed × wall quantities), so speed is impedance-matched" do
      expect(described_class.hazard(status(120), 2.0, 5.0)).
        to be_within(1e-9).of(described_class.hazard(status(240), 1.0, 10.0))
    end

    describe "wall-clock floor (rollovers can't outrun the fixed container reboot)" do
      it "stops climbing with speed above the cap" do
        at_cap = described_class.hazard(status(0), described_class::MAX_ROLL_SPEED, 1.0)
        way_above = described_class.hazard(status(0), described_class::MAX_ROLL_SPEED * 8, 1.0)
        expect(way_above).to eq(at_cap)
      end

      it "floors a fresh container's mean wall interval at MIN_ROLL_WALL_SECONDS" do
        # At any speed, the fresh per-wall-second hazard tops out at 1 / floor.
        rate_per_wall_second = described_class.hazard(status(0), 1000.0, 1.0)
        expect(rate_per_wall_second).to be_within(1e-9).of(1.0 / described_class::MIN_ROLL_WALL_SECONDS)
      end
    end
  end

  describe ".roll" do
    it "never fires on a container's first check (zero-width slice)" do
      expect(described_class.roll(status(0), speed: 1.0, random: 0.0, now: 100.0)).to be_nil
    end

    it "converts the time since the previous check into the probability" do
      described_class.roll(status(0), speed: 1.0, random: 0.99, now: 100.0)
      p = described_class.roll(status(0), speed: 1.0, random: 0.0, now: 160.0)
      expect(p).to eq(described_class.hazard(status(0), 1.0, 60.0))
    end

    it "stays quiet when the draw exceeds the hazard" do
      described_class.roll(status(0), speed: 1.0, random: 0.99, now: 100.0)
      expect(described_class.roll(status(0), speed: 1.0, random: 0.99, now: 160.0)).to be_nil
    end

    it "consumes the slice, so back-to-back checks carry almost no hazard" do
      described_class.roll(status(0), speed: 1.0, random: 0.99, now: 100.0)
      described_class.roll(status(0), speed: 1.0, random: 0.99, now: 160.0)
      p = described_class.roll(status(0), speed: 1.0, random: 0.0, now: 160.5)
      expect(p).to eq(described_class.hazard(status(0), 1.0, 0.5))
    end
  end
end
