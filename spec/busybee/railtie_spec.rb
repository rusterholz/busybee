# frozen_string_literal: true

require "spec_helper"
require "busybee/railtie" if defined?(Rails::Railtie)

# All Busybee config instance variables that the Railtie may set
def busybee_config_ivars
  %i[
    @cluster_address @credential_type @default_fail_job_backoff @default_message_ttl
    @grpc_retry_delay_ms @grpc_retry_enabled @grpc_retry_errors
    @log_format @logger @worker_name
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
  end
end
