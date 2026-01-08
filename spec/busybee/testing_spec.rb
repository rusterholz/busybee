# frozen_string_literal: true

RSpec.describe Busybee::Testing do
  after do
    # Reset configuration after each test
    described_class.address = nil
    described_class.activate_request_timeout = nil
  end

  describe ".configure" do
    it "yields self for configuration" do
      described_class.configure do |config|
        expect(config).to eq(described_class)
      end
    end

    it "allows setting configuration attributes" do
      described_class.configure do |config|
        config.address = "test:26500"
        config.activate_request_timeout = 5000
      end

      expect(described_class.address).to eq("test:26500")
      expect(described_class.activate_request_timeout).to eq(5000)
    end
  end

  describe ".address" do
    it "defaults to ZEEBE_ADDRESS env var" do
      allow(ENV).to receive(:[]).with("ZEEBE_ADDRESS").and_return("custom:26500")
      expect(described_class.address).to eq("custom:26500")
    end

    it "falls back to localhost:26500 when env var not set" do
      allow(ENV).to receive(:[]).with("ZEEBE_ADDRESS").and_return(nil)
      expect(described_class.address).to eq("localhost:26500")
    end

    it "can be set explicitly" do
      described_class.address = "override:26500"
      expect(described_class.address).to eq("override:26500")
    end
  end

  describe ".activate_request_timeout" do
    it "defaults to 1000ms" do
      expect(described_class.activate_request_timeout).to eq(1000)
    end

    it "can be set explicitly" do
      described_class.activate_request_timeout = 5000
      expect(described_class.activate_request_timeout).to eq(5000)
    end
  end
end
