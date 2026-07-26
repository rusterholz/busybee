# frozen_string_literal: true

require "active_support/core_ext/integer/time"
require "busybee/durations"

RSpec.describe Busybee::Durations do
  describe ".milliseconds_from" do
    it "passes Integer milliseconds through" do
      expect(described_class.milliseconds_from(1500)).to eq(1500)
    end

    it "converts an ActiveSupport::Duration to whole milliseconds" do
      expect(described_class.milliseconds_from(30.seconds)).to eq(30_000)
    end

    it "coerces a numeric String" do
      expect(described_class.milliseconds_from("1500")).to eq(1500)
    end
  end

  describe ".seconds_from" do
    it "reads an Integer as milliseconds" do
      expect(described_class.seconds_from(1500)).to eq(1.5)
    end

    it "converts an ActiveSupport::Duration to seconds" do
      expect(described_class.seconds_from(30.seconds)).to eq(30)
    end
  end

  describe ".validate!" do
    it "returns an Integer unchanged" do
      expect(described_class.validate!(:my_knob, 500)).to eq(500)
    end

    it "returns an ActiveSupport::Duration unchanged" do
      duration = 30.seconds
      expect(described_class.validate!(:my_knob, duration)).to be(duration)
    end

    it "coerces a numeric String to Integer" do
      expect(described_class.validate!(:my_knob, "500")).to eq(500)
      expect(described_class.validate!(:my_knob, "2.5")).to eq(2)
    end

    it "raises on a non-numeric String, naming the knob" do
      expect { described_class.validate!(:my_knob, "5 minutes") }.
        to raise_error(ArgumentError, /my_knob.*non-numeric String/)
    end

    it "truncates a stray Numeric with a warning" do
      allow(Busybee::Logging).to receive(:warn)
      expect(described_class.validate!(:my_knob, 2.5)).to eq(2)
      expect(Busybee::Logging).to have_received(:warn).with(/my_knob.*coercing Float/)
    end

    it "raises on anything else, naming the knob" do
      expect { described_class.validate!(:my_knob, :thirty) }.
        to raise_error(ArgumentError, /my_knob.*Integer, ActiveSupport::Duration, or numeric String/)
    end
  end
end
