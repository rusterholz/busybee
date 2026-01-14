# frozen_string_literal: true

# Integration test helper for testing busybee against a real Zeebe instance
#
# Usage:
#   1. Start Zeebe: rake zeebe:start && rake zeebe:health
#   2. Run tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
#
# Tests will skip gracefully if Zeebe is not running, unless ZEEBE_REQUIRED=1
# is set, in which case tests will fail (useful for CI).

module IntegrationHelpers
  # Skips or fails the current test if Zeebe is not available
  #
  # By default, tests skip gracefully when Zeebe is not running (for local dev).
  # Set ZEEBE_REQUIRED=1 to fail instead of skip (for CI).
  #
  # Call this in a before block:
  #
  #   before do
  #     skip_unless_zeebe_available
  #   end
  def skip_unless_zeebe_available
    return if zeebe_available?

    raise "Zeebe is required but not available at #{Busybee.cluster_address}" if ENV["ZEEBE_REQUIRED"]

    skip "Zeebe is not running (start with: rake zeebe:start)"
  end

  # Returns a GRPC stub for Camunda Cloud
  #
  # Raises KeyError with clear message if required environment variables are not set.
  def camunda_cloud_grpc_stub
    @camunda_cloud_grpc_stub ||= camunda_cloud_credentials.grpc_stub
  end

  # Returns a GRPC stub for local Zeebe (alias for consistency with camunda_cloud_grpc_stub)
  def local_grpc_stub
    grpc_client
  end

  # Returns a Busybee::Client configured for Camunda Cloud
  #
  # Raises KeyError with clear message if required environment variables are not set.
  def camunda_cloud_busybee_client
    @camunda_cloud_busybee_client ||= begin
      require "busybee/client"
      Busybee::Client.new(camunda_cloud_credentials)
    end
  end

  # Returns a Busybee::Client configured for local Zeebe
  def local_busybee_client
    @local_busybee_client ||= begin
      require "busybee/client"
      Busybee::Client.new(insecure: true)
    end
  end

  private

  # Returns Camunda Cloud credentials
  #
  # Raises with clear message if required environment variables are not set.
  # Required:
  #   - CAMUNDA_CLIENT_ID
  #   - CAMUNDA_CLIENT_SECRET
  #   - CAMUNDA_CLUSTER_ID
  #   - CAMUNDA_CLUSTER_REGION
  def camunda_cloud_credentials
    @camunda_cloud_credentials ||= begin
      require "busybee/credentials/camunda_cloud"

      fail_if_cloud_credentials_absent!

      Busybee::Credentials::CamundaCloud.new(
        client_id: ENV.fetch("CAMUNDA_CLIENT_ID"),
        client_secret: ENV.fetch("CAMUNDA_CLIENT_SECRET"),
        cluster_id: ENV.fetch("CAMUNDA_CLUSTER_ID"),
        region: ENV.fetch("CAMUNDA_CLUSTER_REGION")
      )
    end
  end

  def fail_if_cloud_credentials_absent!
    # Fail fast if credentials aren't configured
    missing = %w[CAMUNDA_CLIENT_ID CAMUNDA_CLIENT_SECRET CAMUNDA_CLUSTER_ID CAMUNDA_CLUSTER_REGION].reject do |var|
      ENV.fetch(var, nil)
    end
    return if missing.empty?

    raise <<~ERROR
      Camunda Cloud credentials not configured. Missing: #{missing.join(', ')}

      Set these environment variables:
        export CAMUNDA_CLIENT_ID="your-client-id"
        export CAMUNDA_CLIENT_SECRET="your-client-secret"
        export CAMUNDA_CLUSTER_ID="your-cluster-id"
        export CAMUNDA_CLUSTER_REGION="your-region"  # e.g., "bru-2"

      See: https://console.camunda.io/ → Select cluster → API tab
    ERROR
  end
end

RSpec.configure do |config|
  # Include integration helpers in all integration tests
  config.include IntegrationHelpers, integration: true
  config.include IntegrationHelpers, camunda_cloud: true

  # Check Zeebe availability before running integration tests
  config.before(:each, :integration) do
    skip_unless_zeebe_available
  end

  # Filter specs based on multi-tenancy mode
  # - :single_tenant_only specs only run when MULTITENANCY_ENABLED is false/unset
  # - :multi_tenant_only specs only run when MULTITENANCY_ENABLED is true
  # - Untagged specs run in both modes
  multitenancy_enabled = ENV["MULTITENANCY_ENABLED"] == "true"

  if multitenancy_enabled
    config.filter_run_excluding single_tenant_only: true
  else
    config.filter_run_excluding multi_tenant_only: true
  end
end
