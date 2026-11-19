# frozen_string_literal: true

# Specs against a real Zeebe: rake zeebe:start && rake zeebe:health, then
# RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration. They skip when
# Zeebe is down, or fail with ZEEBE_REQUIRED=1 (CI).

module IntegrationHelpers
  # Skips (or, with ZEEBE_REQUIRED=1, fails) when Zeebe is unreachable.
  def skip_unless_zeebe_available
    return if zeebe_available?

    raise "Zeebe is required but not available at #{Busybee.cluster_address}" if ENV["ZEEBE_REQUIRED"]

    skip "Zeebe is not running (start with: rake zeebe:start)"
  end

  # Raises naming the missing variables when cloud credentials aren't set.
  def camunda_cloud_grpc_stub
    @camunda_cloud_grpc_stub ||= camunda_cloud_credentials.grpc_stub
  end

  def local_grpc_stub
    Busybee::Testing::Helpers.grpc_client
  end

  def camunda_cloud_busybee_client
    @camunda_cloud_busybee_client ||= Busybee::Client.new(camunda_cloud_credentials)
  end

  def local_busybee_client
    @local_busybee_client ||= Busybee::Client.new(insecure: true)
  end

  # Whether the connected gateway is at least the given Camunda version, so a
  # spec can pin both what a newer call does and how an older gateway answers it.
  # Compares releases, so a prerelease gateway (8.10.0-alpha1) counts as 8.10.
  def gateway_at_least?(version)
    Gem::Version.new(gateway_version).release >= Gem::Version.new(version)
  end

  # Asked once per process and cluster.
  def gateway_version
    cloud = Busybee.credential_type == :camunda_cloud
    IntegrationHelpers.gateway_versions[cloud] ||=
      (cloud ? camunda_cloud_grpc_stub : local_grpc_stub).topology(Busybee::GRPC::TopologyRequest.new).gatewayVersion
  end

  def self.gateway_versions = (@gateway_versions ||= {})

  private

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
  config.include IntegrationHelpers, integration: true
  config.include IntegrationHelpers, camunda_cloud: true

  config.before(:each, :integration) do
    skip_unless_zeebe_available
  end

  # :single_tenant_only and :multi_tenant_only run in their own mode; untagged, in both.
  multitenancy_enabled = ENV["MULTITENANCY_ENABLED"] == "true"

  if multitenancy_enabled
    config.filter_run_excluding single_tenant_only: true
  else
    config.filter_run_excluding multi_tenant_only: true
  end
end
