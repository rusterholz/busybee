# frozen_string_literal: true

# Load Rails before busybee if testing Rails integration
# This ensures busybee sees Rails::Railtie as defined and loads the railtie
if ENV["TEST_RAILS_INTEGRATION"]
  ENV["RAILS_ENV"] = "test"
  require File.expand_path("dummy/config/environment", __dir__)
end

require "busybee"
require "busybee/testing"
require "base64"
require "securerandom"
require "tempfile"
require "webmock/rspec"

# Load support files
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

# Helper to stub all credential-related env vars to nil for test isolation.
# Call this at the start of any test that needs to control credential env vars,
# then override specific vars as needed for that test.
def stub_credential_env_vars
  allow(ENV).to receive(:fetch).and_call_original
  %w[CAMUNDA_CLIENT_ID CAMUNDA_CLIENT_SECRET CAMUNDA_CLUSTER_ID CAMUNDA_CLUSTER_REGION CLUSTER_ADDRESS
     ZEEBE_AUDIENCE ZEEBE_CERTIFICATE_FILE ZEEBE_SCOPE ZEEBE_TOKEN_URL].each do |var|
    allow(ENV).to receive(:fetch).with(var, nil).and_return(nil)
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Skip specs that require Rails unless Rails::Railtie is available.
  # Try to load it here (without full Rails boot) for unit tests in Rails appraisals.
  # The before hook handles the case where someone runs `--tag rails` directly,
  # which would override filter_run_excluding.
  begin
    require "rails/railtie"
  rescue LoadError
    config.filter_run_excluding rails: true
    config.before(:each, :rails) do
      skip "Requires a Rails appraisal (e.g., `bundle exec appraisal rails-7.1 rspec --tag rails`)"
    end
  end

  # Skip integration tests unless explicitly requested via ENV variable
  # To run integration tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec
  # To run only integration tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
  config.filter_run_excluding integration: true unless ENV["RUN_INTEGRATION_TESTS"]

  # Skip Camunda Cloud integration tests unless explicitly requested
  # These require live credentials and are disabled by default
  # To run: RUN_CAMUNDA_CLOUD_TESTS=1 bundle exec rspec --tag camunda_cloud
  config.filter_run_excluding camunda_cloud: true unless ENV["RUN_CAMUNDA_CLOUD_TESTS"]

  # Allow real HTTP connections for Camunda Cloud integration tests
  config.around(:each, :camunda_cloud) do |example|
    WebMock.allow_net_connect!
    example.run
    WebMock.disable_net_connect!
  end
end
