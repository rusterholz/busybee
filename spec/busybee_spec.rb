# frozen_string_literal: true

require "logger"

RSpec.describe Busybee do
  it "has a version number" do
    expect(Busybee::VERSION).not_to be_nil
  end

  describe ".configure" do
    it "yields self for configuration" do
      expect { |b| described_class.configure(&b) }.to yield_with_args(described_class)
    end
  end

  describe ".cluster_address" do
    around do |example|
      original = described_class.instance_variable_get(:@cluster_address)
      example.run
      described_class.cluster_address = original
    end

    it "returns configured cluster address" do
      described_class.cluster_address = "custom:26500"
      expect(described_class.cluster_address).to eq("custom:26500")
    end

    it "falls back to CLUSTER_ADDRESS env var" do
      described_class.cluster_address = nil
      allow(ENV).to receive(:fetch).with("CLUSTER_ADDRESS", anything).and_return("env:26500")
      expect(described_class.cluster_address).to eq("env:26500")
    end

    it "falls back to localhost:26500" do
      described_class.cluster_address = nil
      allow(ENV).to receive(:fetch).with("CLUSTER_ADDRESS", "localhost:26500").and_return("localhost:26500")
      expect(described_class.cluster_address).to eq("localhost:26500")
    end
  end

  describe ".logger" do
    around do |example|
      original = described_class.instance_variable_get(:@logger)
      example.run
      described_class.logger = original
    end

    it "can be set to a custom logger" do
      custom_logger = Logger.new($stdout)
      described_class.logger = custom_logger
      expect(described_class.logger).to be(custom_logger)
    end

    it "defaults to nil (no logging)" do
      described_class.logger = nil
      expect(described_class.logger).to be_nil
    end
  end
end
