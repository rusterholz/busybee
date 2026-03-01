# frozen_string_literal: true

require "logger"

RSpec.describe Busybee do
  shared_examples "a duration config setter" do |setter, getter, default_const|
    around do |example|
      original = described_class.instance_variable_get(:"@#{getter}")
      example.run
      described_class.public_send(:"#{setter}=", original)
    end

    it "defaults to #{default_const}" do
      described_class.public_send(:"#{setter}=", nil)
      expect(described_class.public_send(getter)).to eq(Busybee::Defaults.const_get(default_const))
    end

    it "accepts an Integer" do
      described_class.public_send(:"#{setter}=", 42_000)
      expect(described_class.public_send(getter)).to eq(42_000)
    end

    it "accepts an ActiveSupport::Duration and returns it as-is" do
      duration = 30.seconds
      described_class.public_send(:"#{setter}=", duration)
      expect(described_class.public_send(getter)).to be(duration)
      expect(described_class.public_send(getter)).to be_a(ActiveSupport::Duration)
    end

    it "coerces a numeric String to Integer" do
      described_class.public_send(:"#{setter}=", "5000")
      expect(described_class.public_send(getter)).to eq(5000)
    end

    it "coerces a decimal String to Integer (truncates)" do
      described_class.public_send(:"#{setter}=", "5000.7")
      expect(described_class.public_send(getter)).to eq(5000)
    end

    it "coerces a Float to Integer with a logged warning" do
      expect(Busybee::Logging).to receive(:warn).with(/coercing Float.*to Integer/) # rubocop:disable RSpec/MessageSpies
      described_class.public_send(:"#{setter}=", 5000.5)
      expect(described_class.public_send(getter)).to eq(5000)
    end

    it "rejects a non-numeric String" do
      expect { described_class.public_send(:"#{setter}=", "five seconds") }.to raise_error(
        ArgumentError, /#{setter}.*non-numeric String/
      )
    end

    it "rejects other types" do
      expect { described_class.public_send(:"#{setter}=", Object.new) }.to raise_error(
        ArgumentError, /#{setter}.*got Object/
      )
    end

    it "resets to default when set to nil" do
      described_class.public_send(:"#{setter}=", 99_999)
      described_class.public_send(:"#{setter}=", nil)
      expect(described_class.public_send(getter)).to eq(Busybee::Defaults.const_get(default_const))
    end
  end

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

    it "accepts a Symbol and coerces to String" do
      described_class.cluster_address = :"custom:26500"
      expect(described_class.cluster_address).to eq("custom:26500")
    end

    it "rejects non-String/Symbol types" do
      expect { described_class.cluster_address = 12_345 }.to raise_error(ArgumentError, /cluster_address/)
    end
  end

  describe ".worker_name" do
    around do |example|
      original = described_class.instance_variable_get(:@worker_name)
      example.run
      described_class.worker_name = original
    end

    it "returns configured worker name" do
      described_class.worker_name = "my-custom-worker"
      allow(ENV).to receive(:[]).with("BUSYBEE_WORKER_NAME").and_return("env-worker")
      allow(Socket).to receive(:gethostname).and_return("hostname")

      expect(described_class.worker_name).to eq("my-custom-worker")
    end

    it "falls back to BUSYBEE_WORKER_NAME env var" do
      described_class.worker_name = nil
      allow(ENV).to receive(:[]).with("BUSYBEE_WORKER_NAME").and_return("env-worker")
      allow(Socket).to receive(:gethostname).and_return("hostname")

      expect(described_class.worker_name).to eq("env-worker")
    end

    it "falls back to hostname when BUSYBEE_WORKER_NAME not set" do
      described_class.worker_name = nil
      allow(ENV).to receive(:[]).with("BUSYBEE_WORKER_NAME").and_return(nil)
      allow(Socket).to receive(:gethostname).and_return("my-hostname")

      expect(described_class.worker_name).to eq("my-hostname")
    end

    it "falls back to busybee-worker when hostname fails" do
      described_class.worker_name = nil
      allow(ENV).to receive(:[]).with("BUSYBEE_WORKER_NAME").and_return(nil)
      allow(Socket).to receive(:gethostname).and_raise(StandardError, "hostname failed")

      expect(described_class.worker_name).to eq("busybee-worker")
    end

    it "accepts a Symbol and coerces to String" do
      described_class.worker_name = :my_worker
      expect(described_class.worker_name).to eq("my_worker")
    end

    it "rejects non-String/Symbol types" do
      expect { described_class.worker_name = 12_345 }.to raise_error(ArgumentError, /worker_name/)
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

    it "rejects non-boolean values" do
      expect { described_class.grpc_retry_enabled = "true" }.to raise_error(ArgumentError, /grpc_retry_enabled/)
      expect { described_class.grpc_retry_enabled = 1 }.to raise_error(ArgumentError, /grpc_retry_enabled/)
    end
  end

  describe ".grpc_retry_delay_ms" do
    it_behaves_like "a duration config setter", :grpc_retry_delay_ms, :grpc_retry_delay_ms,
                    :DEFAULT_GRPC_RETRY_DELAY_MS
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

    it "accepts an Array of exception classes" do
      described_class.grpc_retry_errors = [GRPC::Unavailable]
      expect(described_class.grpc_retry_errors).to eq([GRPC::Unavailable])
    end

    it "rejects a non-Array" do
      expect { described_class.grpc_retry_errors = GRPC::Unavailable }.to raise_error(
        ArgumentError, /grpc_retry_errors.*Array/
      )
    end

    it "rejects Array elements that are not exception classes" do
      expect { described_class.grpc_retry_errors = [String] }.to raise_error(
        ArgumentError, /grpc_retry_errors.*exception classes/
      )
    end

    it "resets to default when set to nil" do
      described_class.grpc_retry_errors = [GRPC::Unavailable]
      described_class.grpc_retry_errors = nil
      expect(described_class.grpc_retry_errors).to contain_exactly(
        GRPC::Unavailable, GRPC::DeadlineExceeded, GRPC::ResourceExhausted
      )
    end
  end

  describe ".default_message_ttl" do
    it_behaves_like "a duration config setter", :default_message_ttl, :default_message_ttl,
                    :DEFAULT_MESSAGE_TTL_MS
  end

  describe ".default_fail_job_backoff" do
    it_behaves_like "a duration config setter", :default_fail_job_backoff, :default_fail_job_backoff,
                    :DEFAULT_FAIL_JOB_BACKOFF_MS
  end

  describe ".default_job_request_timeout" do
    it_behaves_like "a duration config setter", :default_job_request_timeout, :default_job_request_timeout,
                    :DEFAULT_JOB_REQUEST_TIMEOUT_MS
  end

  describe ".default_job_lock_timeout" do
    it_behaves_like "a duration config setter", :default_job_lock_timeout, :default_job_lock_timeout,
                    :DEFAULT_JOB_LOCK_TIMEOUT_MS
  end

  describe ".runner_backpressure_delay" do
    it_behaves_like "a duration config setter", :runner_backpressure_delay, :runner_backpressure_delay,
                    :DEFAULT_RUNNER_BACKPRESSURE_DELAY_MS
  end

  describe ".default_max_jobs" do
    around do |example|
      original = described_class.instance_variable_get(:@default_max_jobs)
      example.run
      described_class.default_max_jobs = original
    end

    it "defaults to 25" do
      described_class.default_max_jobs = nil
      expect(described_class.default_max_jobs).to eq(25)
    end

    it "accepts a positive Integer" do
      described_class.default_max_jobs = 50
      expect(described_class.default_max_jobs).to eq(50)
    end

    it "coerces a numeric String to Integer" do
      described_class.default_max_jobs = "100"
      expect(described_class.default_max_jobs).to eq(100)
    end

    it "rejects zero" do
      expect { described_class.default_max_jobs = 0 }.to raise_error(ArgumentError, /must be positive/)
    end

    it "rejects negative values" do
      expect { described_class.default_max_jobs = -1 }.to raise_error(ArgumentError, /must be positive/)
    end

    it "rejects non-Integer types" do
      expect { described_class.default_max_jobs = 5.5 }.to raise_error(ArgumentError, /default_max_jobs/)
    end

    it "resets to default when set to nil" do
      described_class.default_max_jobs = 50
      described_class.default_max_jobs = nil
      expect(described_class.default_max_jobs).to eq(25)
    end
  end

  describe ".default_input_required" do
    around do |example|
      original = described_class.instance_variable_get(:@default_input_required)
      example.run
      described_class.default_input_required = original
    end

    it "defaults to true" do
      described_class.default_input_required = nil
      expect(described_class.default_input_required).to be(true)
    end

    it "can be set to false" do
      described_class.default_input_required = false
      expect(described_class.default_input_required).to be(false)
    end

    it "rejects non-boolean values" do
      expect { described_class.default_input_required = "true" }.to raise_error(ArgumentError, /default_input_required/)
    end
  end

  describe ".default_output_required" do
    around do |example|
      original = described_class.instance_variable_get(:@default_output_required)
      example.run
      described_class.default_output_required = original
    end

    it "defaults to true" do
      described_class.default_output_required = nil
      expect(described_class.default_output_required).to be(true)
    end

    it "can be set to false" do
      described_class.default_output_required = false
      expect(described_class.default_output_required).to be(false)
    end

    it "rejects non-boolean values" do
      expect { described_class.default_output_required = 0 }.to raise_error(ArgumentError, /default_output_required/)
    end
  end

  describe ".default_queue_enabled" do
    around do |example|
      original = described_class.instance_variable_get(:@default_queue_enabled)
      example.run
      described_class.default_queue_enabled = original
    end

    it "defaults to true" do
      described_class.default_queue_enabled = nil
      expect(described_class.default_queue_enabled).to be(true)
    end

    it "can be set to false" do
      described_class.default_queue_enabled = false
      expect(described_class.default_queue_enabled).to be(false)
    end

    it "rejects non-boolean values" do
      expect { described_class.default_queue_enabled = "true" }.to raise_error(ArgumentError, /default_queue_enabled/)
    end
  end

  describe ".default_queue_throttle" do
    around do |example|
      original = described_class.instance_variable_get(:@default_queue_throttle)
      example.run
      described_class.default_queue_throttle = original
    end

    it "defaults to false (no throttling)" do
      described_class.default_queue_throttle = nil
      expect(described_class.default_queue_throttle).to be(false)
    end

    it "can be set to an integer" do
      described_class.default_queue_throttle = 5
      expect(described_class.default_queue_throttle).to eq(5)
    end

    it "can be set to a float for sub-millisecond precision" do
      described_class.default_queue_throttle = 0.5
      expect(described_class.default_queue_throttle).to eq(0.5)
    end

    it "preserves 0 (minimal throttle via sleep(0))" do
      described_class.default_queue_throttle = 0
      expect(described_class.default_queue_throttle).to eq(0)
    end

    it "coerces true to 0" do
      described_class.default_queue_throttle = true
      expect(described_class.default_queue_throttle).to eq(0)
    end

    it "coerces false to false" do
      described_class.default_queue_throttle = false
      # false is falsy, so reader falls through to default (which is also false)
      expect(described_class.default_queue_throttle).to be(false)
    end

    it "coerces a numeric String to Float" do
      described_class.default_queue_throttle = "5.5"
      expect(described_class.default_queue_throttle).to eq(5.5)
    end

    it "rejects negative values" do
      expect { described_class.default_queue_throttle = -1 }.to raise_error(ArgumentError, /non-negative/)
    end

    it "rejects non-numeric Strings" do
      expect { described_class.default_queue_throttle = "fast" }.to raise_error(ArgumentError, /default_queue_throttle/)
    end

    it "rejects other types" do
      expect { described_class.default_queue_throttle = Object.new }.
        to raise_error(ArgumentError, /default_queue_throttle/)
    end

    it "resets to default when set to nil" do
      described_class.default_queue_throttle = 5
      described_class.default_queue_throttle = nil
      expect(described_class.default_queue_throttle).to be(false)
    end
  end

  describe ".default_runner_mode" do
    around do |example|
      original = described_class.instance_variable_get(:@default_runner_mode)
      example.run
      described_class.default_runner_mode = original
    end

    it "defaults to :hybrid" do
      described_class.default_runner_mode = nil
      expect(described_class.default_runner_mode).to be(:hybrid)
    end

    it "accepts a valid Symbol" do
      described_class.default_runner_mode = :polling
      expect(described_class.default_runner_mode).to be(:polling)
    end

    it "accepts a valid String and coerces to Symbol" do
      described_class.default_runner_mode = "streaming"
      expect(described_class.default_runner_mode).to be(:streaming)
    end

    it "rejects an invalid mode" do
      expect { described_class.default_runner_mode = :turbo }.to raise_error(
        ArgumentError, /default_runner_mode.*:polling.*:streaming.*:hybrid/
      )
    end

    it "rejects non-String/Symbol types" do
      expect { described_class.default_runner_mode = 42 }.to raise_error(ArgumentError, /default_runner_mode/)
    end
  end

  describe ".shutdown_on_errors" do
    around do |example|
      original = described_class.instance_variable_get(:@shutdown_on_errors)
      example.run
      described_class.instance_variable_set(:@shutdown_on_errors, original)
    end

    it "defaults to empty array" do
      described_class.instance_variable_set(:@shutdown_on_errors, nil)
      expect(described_class.shutdown_on_errors).to eq([])
    end

    it "accepts an Array of exception classes" do
      described_class.shutdown_on_errors = [RuntimeError, ArgumentError]
      expect(described_class.shutdown_on_errors).to eq([RuntimeError, ArgumentError])
    end

    it "coerces a single exception class to an Array" do
      described_class.shutdown_on_errors = RuntimeError
      expect(described_class.shutdown_on_errors).to eq([RuntimeError])
    end

    it "rejects non-exception classes in the Array" do
      expect { described_class.shutdown_on_errors = [String] }.to raise_error(
        ArgumentError, /shutdown_on_errors.*exception classes/
      )
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
