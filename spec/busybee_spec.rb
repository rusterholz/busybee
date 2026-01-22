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

  describe ".grpc_retry_enabled" do
    around do |example|
      original = described_class.instance_variable_get(:@grpc_retry_enabled)
      example.run
      described_class.grpc_retry_enabled = original
    end

    it "defaults to false" do
      described_class.grpc_retry_enabled = nil
      expect(described_class.grpc_retry_enabled).to be(false)
    end

    it "can be set to true" do
      described_class.grpc_retry_enabled = true
      expect(described_class.grpc_retry_enabled).to be(true)
    end
  end

  describe ".grpc_retry_delay_ms" do
    around do |example|
      original = described_class.instance_variable_get(:@grpc_retry_delay_ms)
      example.run
      described_class.grpc_retry_delay_ms = original
    end

    it "defaults to 500" do
      described_class.grpc_retry_delay_ms = nil
      expect(described_class.grpc_retry_delay_ms).to eq(500)
    end
  end

  describe ".grpc_retry_errors" do
    around do |example|
      original = described_class.instance_variable_get(:@grpc_retry_errors)
      example.run
      described_class.grpc_retry_errors = original
    end

    it "defaults to common transient errors" do
      described_class.grpc_retry_errors = nil
      expect(described_class.grpc_retry_errors).to contain_exactly(
        GRPC::Unavailable,
        GRPC::DeadlineExceeded,
        GRPC::ResourceExhausted
      )
    end
  end

  describe ".default_message_ttl" do
    around do |example|
      original = described_class.instance_variable_get(:@default_message_ttl)
      example.run
      described_class.default_message_ttl = original
    end

    it "defaults to Defaults::DEFAULT_MESSAGE_TTL_MS" do
      described_class.default_message_ttl = nil
      expect(described_class.default_message_ttl).to eq(Busybee::Defaults::DEFAULT_MESSAGE_TTL_MS)
    end

    it "can be set to a custom integer value" do
      described_class.default_message_ttl = 30_000
      expect(described_class.default_message_ttl).to eq(30_000)
    end

    it "can be set to an ActiveSupport::Duration and returns the Duration" do
      duration = 30.seconds
      described_class.default_message_ttl = duration
      expect(described_class.default_message_ttl).to be(duration)
      expect(described_class.default_message_ttl).to be_a(ActiveSupport::Duration)
    end
  end

  describe ".default_fail_job_backoff" do
    around do |example|
      original = described_class.instance_variable_get(:@default_fail_job_backoff)
      example.run
      described_class.default_fail_job_backoff = original
    end

    it "defaults to Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS" do
      described_class.default_fail_job_backoff = nil
      expect(described_class.default_fail_job_backoff).to eq(Busybee::Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS)
    end

    it "can be set to a custom integer value" do
      described_class.default_fail_job_backoff = 10_000
      expect(described_class.default_fail_job_backoff).to eq(10_000)
    end

    it "can be set to an ActiveSupport::Duration and returns the Duration" do
      duration = 10.seconds
      described_class.default_fail_job_backoff = duration
      expect(described_class.default_fail_job_backoff).to be(duration)
      expect(described_class.default_fail_job_backoff).to be_a(ActiveSupport::Duration)
    end
  end

  describe ".credentials" do
    it "can be set and retrieved with valid credentials object" do
      creds = Busybee::Credentials.new
      described_class.credentials = creds
      expect(described_class.credentials).to be(creds)
    end

    it "can be set to nil" do
      described_class.credentials = nil
      expect(described_class.credentials).to be_nil
    end

    it "raises ArgumentError when set to non-Credentials object" do
      expect { described_class.credentials = "invalid" }.to raise_error(
        ArgumentError,
        /credentials must be a Busybee::Credentials object, got String/
      )
    end
  end

  describe ".log_format" do
    around do |example|
      original_format = described_class.instance_variable_get(:@log_format)
      original_logger = described_class.logger
      example.run
      described_class.instance_variable_set(:@log_format, original_format)
      described_class.logger = original_logger
    end

    it "defaults to :text" do
      described_class.instance_variable_set(:@log_format, nil)
      expect(described_class.log_format).to be(:text)
    end

    it "accepts valid format as string and returns symbol" do
      described_class.log_format = "json"
      expect(described_class.log_format).to be(:json)
    end

    it "accepts valid format as symbol and returns symbol" do
      described_class.log_format = :json
      expect(described_class.log_format).to be(:json)
    end

    it "rejects invalid format and returns default when no previous value set" do
      described_class.instance_variable_set(:@log_format, nil)
      described_class.log_format = "invalid"
      expect(described_class.log_format).to be(:text)
    end

    it "does not clobber previous valid value when invalid value is set" do
      described_class.log_format = "json"
      described_class.log_format = "invalid"
      expect(described_class.log_format).to be(:json)
    end

    it "logs warning when invalid format is set" do
      logger = instance_double(Logger)
      described_class.logger = logger
      expect(Busybee::Logging).to receive(:warn).with(/Invalid log_format.*invalid.*Valid formats: text, json/) # rubocop:disable RSpec/MessageSpies
      described_class.log_format = "invalid"
    end

    it "allows setting to nil explicitly" do
      described_class.log_format = "json"
      described_class.log_format = nil
      expect(described_class.log_format).to be(:text)
    end
  end

  describe ".credential_type" do
    around do |example|
      original_type = described_class.instance_variable_get(:@credential_type)
      original_logger = described_class.logger
      example.run
      described_class.instance_variable_set(:@credential_type, original_type)
      described_class.logger = original_logger
    end

    it "accepts valid type as string and returns symbol" do
      described_class.credential_type = "insecure"
      expect(described_class.credential_type).to be(:insecure)
    end

    it "accepts valid type as symbol and returns symbol" do
      described_class.credential_type = :insecure
      expect(described_class.credential_type).to be(:insecure)
    end

    it "rejects invalid type and returns nil when no previous value set" do
      described_class.instance_variable_set(:@credential_type, nil)
      described_class.credential_type = "invalid"
      expect(described_class.credential_type).to be_nil
    end

    it "does not clobber previous valid value when invalid value is set" do
      described_class.credential_type = "insecure"
      described_class.credential_type = "invalid"
      expect(described_class.credential_type).to be(:insecure)
    end

    it "logs warning when invalid type is set" do
      logger = instance_double(Logger)
      described_class.logger = logger
      expect(logger).to receive(:warn).with(/Invalid credential_type.*invalid.*Valid types: insecure/) # rubocop:disable RSpec/MessageSpies
      described_class.credential_type = "invalid"
    end

    it "does not log warning when logger is nil" do
      described_class.logger = nil
      expect { described_class.credential_type = "invalid" }.not_to raise_error
    end

    it "falls back to BUSYBEE_CREDENTIAL_TYPE env var" do
      described_class.instance_variable_set(:@credential_type, nil)
      allow(ENV).to receive(:fetch).with("BUSYBEE_CREDENTIAL_TYPE", nil).and_return("insecure")
      expect(described_class.credential_type).to be(:insecure)
    end

    it "validates env var value" do
      described_class.instance_variable_set(:@credential_type, nil)
      allow(ENV).to receive(:fetch).with("BUSYBEE_CREDENTIAL_TYPE", nil).and_return("invalid")
      expect(described_class.credential_type).to be_nil
    end

    it "returns nil when not configured" do
      described_class.instance_variable_set(:@credential_type, nil)
      allow(ENV).to receive(:fetch).with("BUSYBEE_CREDENTIAL_TYPE", nil).and_return(nil)
      expect(described_class.credential_type).to be_nil
    end

    it "allows setting to nil explicitly" do
      described_class.credential_type = "insecure"
      described_class.credential_type = nil
      expect(described_class.credential_type).to be_nil
    end
  end
end
