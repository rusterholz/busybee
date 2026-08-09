# frozen_string_literal: true

# This spec tests the Railtie with a real Rails boot via the demo app.
# It requires TEST_RAILS_INTEGRATION=1 to run, which loads the demo Rails app.
#
# To run: TEST_RAILS_INTEGRATION=1 bundle exec rspec spec/integration/rails/railtie_spec.rb

RSpec.describe "Railtie integration with demo Rails app", :rails do
  # These tests only make sense when we've booted the full Rails app
  before do
    skip "Requires TEST_RAILS_INTEGRATION=1 to boot demo Rails app" unless ENV["TEST_RAILS_INTEGRATION"]
  end

  describe "after Rails initialization" do
    it "loads the Railtie" do
      expect(defined?(Busybee::Railtie)).to eq("constant")
    end

    it "registers the busybee.configure initializer" do
      initializer_names = Rails.application.initializers.map(&:name)
      expect(initializer_names).to include("busybee.configure")
    end

    it "sets Busybee.logger to Rails.logger" do
      expect(Busybee.logger).to eq(Rails.logger)
    end
  end

  describe "configuration from config.x.busybee" do
    # The dummy app sets distinct values (not defaults) to verify wiring works.
    # See spec/demo/config/application.rb for the configured values.

    it "sets cluster_address from config" do
      expect(Busybee.cluster_address).to eq("dummy.zeebe.test:443")
    end

    it "sets credential_type from config" do
      expect(Busybee.credential_type).to eq(:tls)
    end

    it "sets worker_name from config" do
      expect(Busybee.worker_name).to eq("dummy-test-worker")
    end

    it "sets grpc_retry_enabled from config" do
      expect(Busybee.grpc_retry_enabled).to be true
    end

    it "sets grpc_retry_delay from config" do
      expect(Busybee.grpc_retry_delay).to eq(250)
    end

    it "sets default_message_ttl from config" do
      expect(Busybee.default_message_ttl).to eq(30_000)
    end

    it "sets default_fail_job_backoff from config" do
      expect(Busybee.default_fail_job_backoff).to eq(10_000)
    end

    it "sets default_polling_request_timeout from config" do
      expect(Busybee.default_polling_request_timeout).to eq(30_000)
    end

    it "sets default_job_timeout from config" do
      expect(Busybee.default_job_timeout).to eq(120_000)
    end

    it "sets log_format from config" do
      expect(Busybee.log_format).to eq(:json)
    end

    it "builds TLS credentials object from config" do
      expect(Busybee.credentials).to be_a(Busybee::Credentials::TLS)
    end

    it "uses cluster_address from config for built credentials" do
      expect(Busybee.credentials.cluster_address).to eq("dummy.zeebe.test:443")
    end
  end
end
