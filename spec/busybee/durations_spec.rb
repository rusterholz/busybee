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

    # Duration#in_seconds truncates to Integer, so a sub-second Duration used to
    # come back as 0 — "sleep" turning into "don't sleep". Every consumer of this
    # method takes a Float natively (three sleeps and a Time addition), so there
    # is nothing downstream that wanted the truncation.
    it "keeps the fraction of a sub-second Duration" do
      expect(described_class.seconds_from(0.25.seconds)).to eq(0.25)
    end

    it "keeps the remainder of a fractional Duration" do
      expect(described_class.seconds_from(1.5.seconds)).to eq(1.5)
    end

    # The magnitude the backpressure corridor deliberately doesn't wait for.
    it "reads the shipped backpressure default as two seconds" do
      expect(described_class.seconds_from(Busybee::Defaults::DEFAULT_BACKPRESSURE_DELAY_MS)).to eq(2.0)
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

    it "coerces a whole numeric String to Integer" do
      expect(described_class.validate!(:my_knob, "500")).to eq(500)
    end

    it "keeps the fraction of a decimal numeric String" do
      expect(described_class.validate!(:my_knob, "2.5")).to eq(2.5)
    end

    it "raises on a non-numeric String, naming the knob" do
      expect { described_class.validate!(:my_knob, "5 minutes") }.
        to raise_error(ArgumentError, /my_knob.*non-numeric String/)
    end

    # Truncation belongs at the wire, where milliseconds_from already does it —
    # not here. Rounding at the setter is what forced buffer_throttle, whose
    # sub-millisecond values are a documented feature, to keep its own validator.
    it "returns a Float unchanged" do
      expect(described_class.validate!(:my_knob, 2.5)).to eq(2.5)
    end

    it "raises on anything else, naming the knob" do
      expect { described_class.validate!(:my_knob, :thirty) }.
        to raise_error(ArgumentError, /my_knob.*number, ActiveSupport::Duration, or numeric String/)
    end

    # The knob accepts it, and 2 is a legal number of milliseconds — but a
    # message that lives 2ms is almost always someone who meant 2 seconds. The
    # value is honoured either way; the operator just gets told.
    describe "implausibly small values" do
      before { allow(Busybee::Logging).to receive(:warn) }

      it "warns when a value falls far below what its knob wants" do
        described_class.validate!(:default_message_ttl, 2)
        expect(Busybee::Logging).to have_received(:warn).with(/default_message_ttl.*2ms/)
      end

      # The check runs on the resolved milliseconds, so the spelling that hides
      # the mistake best is caught the same as the bare number.
      it "warns on a Duration that resolves just as small" do
        described_class.validate!(:default_message_ttl, 0.002.seconds)
        expect(Busybee::Logging).to have_received(:warn).with(/default_message_ttl/)
      end

      it "stays quiet for a plausible value" do
        described_class.validate!(:default_message_ttl, 10.seconds)
        expect(Busybee::Logging).not_to have_received(:warn)
      end

      # Zero and negatives are sentinels, not slips: "no delay", and -1 for
      # "answer immediately, don't long-poll". A units slip lands nonzero.
      it "stays quiet for the zero and sentinel values" do
        described_class.validate!(:default_backpressure_delay, 0)
        described_class.validate!(:request_timeout, -1)
        expect(Busybee::Logging).not_to have_received(:warn)
      end

      it "stays quiet for a knob with no floor, however small" do
        described_class.validate!(:buffer_throttle, 0.1)
        expect(Busybee::Logging).not_to have_received(:warn)
      end
    end
  end
end
