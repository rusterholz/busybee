# frozen_string_literal: true

RSpec.describe Busybee::Testing do
  after do
    # Reset configuration after each test
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
        config.activate_request_timeout = 5000
      end

      expect(described_class.activate_request_timeout).to eq(5000)
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
