# frozen_string_literal: true

require "busybee/hooks/timing"

RSpec.describe Busybee::Hooks::Timing do
  # A throwaway host exercising the mixin's contract directly, independent of
  # the concrete carriers (Job/Call/Worker ::Timestamps) that include it.
  let(:host_class) do
    Class.new do
      include Busybee::Hooks::Timing

      timestamp :alpha, :omega

      def span_ms
        elapsed_ms(:alpha, :omega)
      end
    end
  end

  it "defines paired readers that are nil until stamped" do
    expect(host_class.new.alpha).to be_nil
  end

  it "stamps a UTC Time and a monotonic Float pair" do
    host = host_class.new
    host.stamp!(:alpha)
    expect(host.alpha).to be_a(Time)
    expect(host.alpha(:monotonic)).to be_a(Float)
  end

  it "defaults the reader kind to :utc" do
    host = host_class.new.tap { |h| h.stamp!(:alpha) }
    expect(host.alpha).to eq(host.alpha(:utc))
  end

  it "raises on an unknown reader kind" do
    host = host_class.new.tap { |h| h.stamp!(:alpha) }
    expect { host.alpha(:bogus) }.to raise_error(ArgumentError, /:utc or :monotonic/)
  end

  it "returns self from stamp! for chaining" do
    host = host_class.new
    expect(host.stamp!(:alpha)).to be(host)
  end

  it "measures elapsed ms over a private moment that has no public reader" do
    host = host_class.new
    host.stamp!(:alpha)
    host.stamp!(:undeclared) # no reader defined, but stamp!/elapsed_ms still work
    expect(host.send(:elapsed_ms, :alpha, :undeclared)).to be >= 0
  end

  it "measures non-negative elapsed ms between two stamped moments" do
    host = host_class.new
    host.stamp!(:alpha)
    host.stamp!(:omega)
    expect(host.span_ms).to be >= 0
  end

  it "returns nil elapsed ms when an endpoint is unstamped" do
    host = host_class.new.tap { |h| h.stamp!(:alpha) }
    expect(host.span_ms).to be_nil
  end

  describe ".timestamp_names" do
    it "records the declared moments in declaration order" do
      expect(host_class.timestamp_names).to eq(%i[alpha omega])
    end
  end

  describe "#timestamp_hash" do
    it "is empty before any stamping" do
      expect(host_class.new.timestamp_hash).to eq({})
    end

    it "maps each stamped declared moment to its UTC stamp by default" do
      host = host_class.new
      host.stamp!(:alpha)
      host.stamp!(:omega)

      hash = host.timestamp_hash
      expect(hash.keys).to contain_exactly(:alpha, :omega)
      expect(hash[:alpha]).to be_a(Time)
    end

    it "omits declared moments that haven't been stamped" do
      host = host_class.new.tap { |h| h.stamp!(:alpha) }
      expect(host.timestamp_hash.keys).to eq([:alpha])
    end

    it "reads the monotonic stamps when asked" do
      host = host_class.new.tap { |h| h.stamp!(:alpha) }
      expect(host.timestamp_hash(:monotonic)[:alpha]).to be_a(Float)
    end

    it "excludes stamped moments that were never declared" do
      host = host_class.new
      host.stamp!(:alpha)
      host.stamp!(:undeclared)
      expect(host.timestamp_hash.keys).to eq([:alpha])
    end
  end
end
