# frozen_string_literal: true

require "spec_helper"
require "busybee/railtie" if defined?(Rails::Railtie)
require "busybee/credentials/insecure"

# All Busybee config instance variables that the Railtie may set
def busybee_config_ivars
  %i[
    @cluster_address @credential_type @credentials @default_fail_job_backoff
    @default_job_lock_timeout @default_job_request_timeout @default_max_jobs
    @default_message_ttl @default_buffer @default_buffer_throttle
    @grpc_retry_delay_ms @grpc_retry_enabled @grpc_retry_errors
    @log_format @logger @default_backpressure_delay
    @worker_name
  ]
end

# Use string description to avoid NameError when Rails::Railtie not available
RSpec.describe "Busybee::Railtie", :rails do
  # Reference the actual class (safe because this only runs when :rails tag is not excluded)
  let(:railtie_class) { Busybee::Railtie }

  # Store original values to restore after each test
  around do |example|
    original_values = busybee_config_ivars.to_h { |ivar| [ivar, Busybee.instance_variable_get(ivar)] }
    example.run
  ensure
    original_values.each { |ivar, value| Busybee.instance_variable_set(ivar, value) }
  end

  describe "class definition" do
    it "is defined when Rails is present" do
      expect(defined?(Busybee::Railtie)).to eq("constant")
    end

    it "is a Rails::Railtie" do
      expect(railtie_class.superclass).to eq(Rails::Railtie)
    end
  end

  describe "configuration wiring" do
    # Set up a minimal Rails application for testing
    let(:rails_config) do
      config = ActiveSupport::OrderedOptions.new
      config.x = ActiveSupport::OrderedOptions.new
      config.x.busybee = ActiveSupport::OrderedOptions.new
      config
    end

    let(:rails_app) do
      app = instance_double(Rails::Application)
      allow(app).to receive(:config).and_return(rails_config)
      app
    end

    let(:rails_logger) { Logger.new(StringIO.new) }

    before do
      allow(Rails).to receive_messages(application: rails_app, configuration: rails_config, logger: rails_logger)
    end

    # Helper to reset all Busybee config to nil
    def reset_busybee_config!
      busybee_config_ivars.each { |ivar| Busybee.instance_variable_set(ivar, nil) }
    end

    # Helper to simulate Railtie initialization with given config
    def configure_and_initialize(**settings)
      reset_busybee_config!
      settings.each { |k, v| rails_config.x.busybee[k] = v }
      railtie_class.initializers.find { |i| i.name == "busybee.configure" }.run(rails_app)
    end

    describe "logger" do
      it "defaults to Rails.logger when not configured" do
        configure_and_initialize
        expect(Busybee.logger).to eq(rails_logger)
      end

      it "uses custom logger when configured" do
        custom_logger = Logger.new(StringIO.new)
        configure_and_initialize(logger: custom_logger)
        expect(Busybee.logger).to eq(custom_logger)
      end

      it "disables logging when set to false" do
        configure_and_initialize(logger: false)
        expect(Busybee.logger).to be_nil
      end

      it "falls back to Rails.logger when set to true" do
        configure_and_initialize(logger: true)
        expect(Busybee.logger).to eq(rails_logger)
      end
    end

    describe "log_format" do
      it "sets log_format when configured" do
        configure_and_initialize(log_format: :json)
        expect(Busybee.log_format).to eq(:json)
      end

      it "leaves default when not configured" do
        configure_and_initialize
        expect(Busybee.log_format).to eq(:text)
      end
    end

    describe "cluster_address" do
      it "sets cluster_address when configured" do
        configure_and_initialize(cluster_address: "zeebe.example.com:443")
        expect(Busybee.instance_variable_get(:@cluster_address)).to eq("zeebe.example.com:443")
      end

      it "leaves nil when not configured" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@cluster_address)).to be_nil
      end
    end

    describe "credential_type" do
      it "sets credential_type when configured" do
        configure_and_initialize(credential_type: :oauth)
        expect(Busybee.credential_type).to eq(:oauth)
      end

      it "leaves nil when not configured" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@credential_type)).to be_nil
      end
    end

    describe "worker_name" do
      it "sets worker_name when configured" do
        configure_and_initialize(worker_name: "test-worker")
        expect(Busybee.instance_variable_get(:@worker_name)).to eq("test-worker")
      end

      it "leaves nil when not configured" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@worker_name)).to be_nil
      end
    end

    describe "grpc_retry_enabled" do
      it "sets grpc_retry_enabled to true when configured" do
        configure_and_initialize(grpc_retry_enabled: true)
        expect(Busybee.grpc_retry_enabled).to be true
      end

      it "sets grpc_retry_enabled to false when explicitly configured" do
        configure_and_initialize(grpc_retry_enabled: false)
        expect(Busybee.grpc_retry_enabled).to be false
      end

      it "leaves default (false) when not configured" do
        configure_and_initialize
        expect(Busybee.grpc_retry_enabled).to be false
      end
    end

    describe "grpc_retry_delay_ms" do
      it "sets grpc_retry_delay_ms when configured" do
        configure_and_initialize(grpc_retry_delay_ms: 1000)
        expect(Busybee.instance_variable_get(:@grpc_retry_delay_ms)).to eq(1000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@grpc_retry_delay_ms)).to be_nil
        expect(Busybee.grpc_retry_delay_ms).to eq(Busybee::Defaults::DEFAULT_GRPC_RETRY_DELAY_MS)
      end
    end

    describe "grpc_retry_errors" do
      it "sets grpc_retry_errors when configured" do
        configure_and_initialize(grpc_retry_errors: [GRPC::Unavailable])
        expect(Busybee.instance_variable_get(:@grpc_retry_errors)).to eq([GRPC::Unavailable])
      end

      it "leaves nil when not configured (uses default)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@grpc_retry_errors)).to be_nil
      end
    end

    describe "default_message_ttl" do
      it "sets default_message_ttl when configured" do
        configure_and_initialize(default_message_ttl: 60_000)
        expect(Busybee.instance_variable_get(:@default_message_ttl)).to eq(60_000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_message_ttl)).to be_nil
        expect(Busybee.default_message_ttl).to eq(Busybee::Defaults::DEFAULT_MESSAGE_TTL_MS)
      end
    end

    describe "default_fail_job_backoff" do
      it "sets default_fail_job_backoff when configured" do
        configure_and_initialize(default_fail_job_backoff: 15_000)
        expect(Busybee.instance_variable_get(:@default_fail_job_backoff)).to eq(15_000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_fail_job_backoff)).to be_nil
        expect(Busybee.default_fail_job_backoff).to eq(Busybee::Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS)
      end
    end

    describe "default_job_request_timeout" do
      it "sets default_job_request_timeout when configured" do
        configure_and_initialize(default_job_request_timeout: 30_000)
        expect(Busybee.instance_variable_get(:@default_job_request_timeout)).to eq(30_000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_job_request_timeout)).to be_nil
        expect(Busybee.default_job_request_timeout).to eq(Busybee::Defaults::DEFAULT_JOB_REQUEST_TIMEOUT_MS)
      end
    end

    describe "default_job_lock_timeout" do
      it "sets default_job_lock_timeout when configured" do
        configure_and_initialize(default_job_lock_timeout: 120_000)
        expect(Busybee.instance_variable_get(:@default_job_lock_timeout)).to eq(120_000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_job_lock_timeout)).to be_nil
        expect(Busybee.default_job_lock_timeout).to eq(Busybee::Defaults::DEFAULT_JOB_LOCK_TIMEOUT_MS)
      end
    end

    describe "default_backpressure_delay" do
      it "sets default_backpressure_delay when configured" do
        configure_and_initialize(default_backpressure_delay: 15_000)
        expect(Busybee.instance_variable_get(:@default_backpressure_delay)).to eq(15_000)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_backpressure_delay)).to be_nil
        expect(Busybee.default_backpressure_delay).to eq(Busybee::Defaults::DEFAULT_BACKPRESSURE_DELAY_MS)
      end
    end

    describe "default_max_jobs" do
      it "sets default_max_jobs when configured" do
        configure_and_initialize(default_max_jobs: 50)
        expect(Busybee.instance_variable_get(:@default_max_jobs)).to eq(50)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_max_jobs)).to be_nil
        expect(Busybee.default_max_jobs).to eq(Busybee::Defaults::DEFAULT_MAX_JOBS)
      end
    end

    describe "default_buffer" do
      it "sets default_buffer when configured" do
        configure_and_initialize(default_buffer: false)
        expect(Busybee.instance_variable_get(:@default_buffer)).to be(false)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_buffer)).to be_nil
        expect(Busybee.default_buffer).to be(true)
      end
    end

    describe "default_buffer_throttle" do
      it "sets default_buffer_throttle when configured" do
        configure_and_initialize(default_buffer_throttle: 0.5)
        expect(Busybee.instance_variable_get(:@default_buffer_throttle)).to eq(0.5)
      end

      it "leaves nil when not configured (uses default from Defaults)" do
        configure_and_initialize
        expect(Busybee.instance_variable_get(:@default_buffer_throttle)).to be_nil
        expect(Busybee.default_buffer_throttle).to be(false)
      end
    end

    describe "credentials building" do
      it "uses explicit Credentials object when provided" do
        explicit_creds = Busybee::Credentials::Insecure.new(cluster_address: "explicit:26500")
        configure_and_initialize(credentials: explicit_creds)

        expect(Busybee.credentials).to eq(explicit_creds)
      end

      it "does not build credentials when only credential_type is set (uses ENV fallback)" do
        configure_and_initialize(credential_type: :insecure)

        expect(Busybee.credential_type).to eq(:insecure)
        expect(Busybee.credentials).to be_nil
      end

      it "builds Insecure credentials from type and cluster_address" do
        configure_and_initialize(
          credential_type: :insecure,
          cluster_address: "local.zeebe:26500"
        )

        expect(Busybee.credentials).to be_a(Busybee::Credentials::Insecure)
        expect(Busybee.credentials.cluster_address).to eq("local.zeebe:26500")
      end

      it "builds CamundaCloud credentials from type and params" do
        # Stub the token endpoint to avoid real HTTP calls
        stub_request(:post, "https://login.cloud.camunda.io/oauth/token").
          to_return(status: 200, body: { access_token: "test", expires_in: 3600 }.to_json)

        configure_and_initialize(
          credential_type: :camunda_cloud,
          client_id: "my-client-id",
          client_secret: "my-client-secret",
          cluster_id: "abc-123",
          region: "bru-2"
        )

        expect(Busybee.credentials).to be_a(Busybee::Credentials::CamundaCloud)
        expect(Busybee.credentials.cluster_address).to eq("abc-123.bru-2.zeebe.camunda.io:443")
      end

      it "builds OAuth credentials from type and params" do
        # Stub the token endpoint to avoid real HTTP calls
        stub_request(:post, "https://auth.example.com/token").
          to_return(status: 200, body: { access_token: "test", expires_in: 3600 }.to_json)

        configure_and_initialize(
          credential_type: :oauth,
          token_url: "https://auth.example.com/token",
          client_id: "oauth-client",
          client_secret: "oauth-secret",
          audience: "zeebe-api",
          cluster_address: "oauth.zeebe:443"
        )

        expect(Busybee.credentials).to be_a(Busybee::Credentials::OAuth)
        expect(Busybee.credentials.cluster_address).to eq("oauth.zeebe:443")
      end

      it "builds TLS credentials from type and cluster_address" do
        configure_and_initialize(
          credential_type: :tls,
          cluster_address: "secure.zeebe:443"
        )

        expect(Busybee.credentials).to be_a(Busybee::Credentials::TLS)
        expect(Busybee.credentials.cluster_address).to eq("secure.zeebe:443")
      end

      it "raises ArgumentError when CamundaCloud params are incomplete" do
        expect do
          configure_and_initialize(
            credential_type: :camunda_cloud,
            client_id: "my-client-id",
            # missing client_secret, cluster_id, region
            cluster_address: "somewhere:443"
          )
        end.to raise_error(ArgumentError, /client_secret is required/)
      end

      it "raises ArgumentError when OAuth params are incomplete" do
        expect do
          configure_and_initialize(
            credential_type: :oauth,
            client_id: "my-client-id",
            # missing token_url, client_secret, audience
            cluster_address: "somewhere:443"
          )
        end.to raise_error(ArgumentError, /token_url is required/)
      end

      it "prefers explicit Credentials object over type + params" do
        explicit_creds = Busybee::Credentials::Insecure.new(cluster_address: "explicit:26500")

        configure_and_initialize(
          credentials: explicit_creds,
          credential_type: :camunda_cloud,
          client_id: "should-be-ignored",
          client_secret: "should-be-ignored",
          cluster_id: "should-be-ignored",
          region: "should-be-ignored"
        )

        expect(Busybee.credentials).to eq(explicit_creds)
        expect(Busybee.credentials.cluster_address).to eq("explicit:26500")
      end

      it "raises ArgumentError when credential_type mismatches params (CamundaCloud params with :oauth type)" do
        # CamundaCloud params don't include token_url/audience which OAuth requires
        expect do
          configure_and_initialize(
            credential_type: :oauth,
            client_id: "my-client-id",
            client_secret: "my-client-secret",
            cluster_id: "abc-123",
            region: "bru-2"
          )
        end.to raise_error(ArgumentError, /token_url is required/)
      end

      it "uses configured credential_type even when params could match multiple types" do
        # These params could work for either OAuth or CamundaCloud autodetection,
        # but explicit credential_type: :oauth should win
        stub_request(:post, "https://auth.example.com/token").
          to_return(status: 200, body: { access_token: "test", expires_in: 3600 }.to_json)

        configure_and_initialize(
          credential_type: :oauth,
          token_url: "https://auth.example.com/token",
          client_id: "dual-use-client",
          client_secret: "dual-use-secret",
          audience: "zeebe-api",
          cluster_id: "abc-123",     # CamundaCloud param (ignored)
          region: "bru-2",           # CamundaCloud param (ignored)
          cluster_address: "oauth.zeebe:443"
        )

        expect(Busybee.credentials).to be_a(Busybee::Credentials::OAuth)
        expect(Busybee.credentials.cluster_address).to eq("oauth.zeebe:443")
      end

      it "uses autodetection when credential_type is omitted but params are sufficient" do
        # Stub the token endpoint for CamundaCloud
        stub_request(:post, "https://login.cloud.camunda.io/oauth/token").
          to_return(status: 200, body: { access_token: "test", expires_in: 3600 }.to_json)

        configure_and_initialize(
          client_id: "autodetect-client",
          client_secret: "autodetect-secret",
          cluster_id: "abc-123",
          region: "bru-2"
        )

        expect(Busybee.credential_type).to be_nil
        expect(Busybee.credentials).to be_a(Busybee::Credentials::CamundaCloud)
        expect(Busybee.credentials.cluster_address).to eq("abc-123.bru-2.zeebe.camunda.io:443")
      end

      it "raises CannotDetectCredentials when params are incomplete and no credential_type" do
        expect do
          configure_and_initialize(
            client_id: "orphan-client",
            # Missing other required params for any credential type
            cluster_address: "somewhere:443"
          )
        end.to raise_error(Busybee::CannotDetectCredentials)
      end
    end
  end
end
