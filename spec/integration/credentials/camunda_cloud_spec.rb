# frozen_string_literal: true

require "busybee/credentials/camunda_cloud"

# IMPORTANT: This test requires live Camunda Cloud credentials.
# Maintainers must set these environment variables to run this test:
#
#   export CAMUNDA_CLIENT_ID="your-client-id"
#   export CAMUNDA_CLIENT_SECRET="your-client-secret"
#   export CAMUNDA_CLUSTER_ID="your-cluster-id"
#   export CAMUNDA_CLUSTER_REGION="bru-2"  # or your cluster's region
#
# These credentials can be obtained from Camunda Console:
#   1. Go to https://console.camunda.io/
#   2. Select your cluster
#   3. Navigate to API tab
#   4. Create a new client with "Zeebe" permissions
#
# macOS users: Set GRPC_DNS_RESOLVER=native in ~/.bashrc (see docs/development.md)
#
# To run: RUN_CAMUNDA_CLOUD_TESTS=1 bundle exec rspec --tag camunda_cloud
#
RSpec.describe "Camunda Cloud integration", :camunda_cloud do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    skip "Camunda Cloud credentials not configured" unless ENV["CAMUNDA_CLIENT_ID"]

    # Warn if using c-ares on macOS (known to fail)
    if RUBY_PLATFORM.include?("darwin") && ENV["GRPC_DNS_RESOLVER"] != "native"
      warn "\n⚠️  Warning: c-ares DNS resolver has known issues on macOS."
      warn "   Add 'export GRPC_DNS_RESOLVER=native' to your ~/.bashrc"
      warn "   See docs/development.md for details.\n\n"
    end
  end

  let(:simple_bpmn_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }

  describe "cluster address derivation" do
    it "derives correct cluster address from cluster_id and region" do
      credentials = Busybee::Credentials::CamundaCloud.new(
        client_id: ENV.fetch("CAMUNDA_CLIENT_ID"),
        client_secret: ENV.fetch("CAMUNDA_CLIENT_SECRET"),
        cluster_id: ENV.fetch("CAMUNDA_CLUSTER_ID"),
        region: ENV.fetch("CAMUNDA_CLUSTER_REGION", "bru-2")
      )

      cluster_id = ENV.fetch("CAMUNDA_CLUSTER_ID")
      region = ENV.fetch("CAMUNDA_CLUSTER_REGION", "bru-2")

      expected_address = "#{cluster_id}.#{region}.zeebe.camunda.io:443"
      expect(credentials.cluster_address).to eq(expected_address)
    end
  end

  # Test both with and without scope parameter to verify OAuth audience is correct
  [nil, "Zeebe"].each do |scope_value|
    context "with#{'out' unless scope_value} scope parameter" do
      let(:credentials) do
        Busybee::Credentials::CamundaCloud.new(
          client_id: ENV.fetch("CAMUNDA_CLIENT_ID"),
          client_secret: ENV.fetch("CAMUNDA_CLIENT_SECRET"),
          cluster_id: ENV.fetch("CAMUNDA_CLUSTER_ID"),
          region: ENV.fetch("CAMUNDA_CLUSTER_REGION", "bru-2"),
          scope: scope_value
        )
      end

      it "successfully authenticates and can fetch cluster topology" do
        stub = credentials.grpc_stub
        request = Busybee::GRPC::TopologyRequest.new

        # This triggers actual OAuth token fetch and validates our audience is correct
        response = stub.topology(request)

        expect(response).to be_a(Busybee::GRPC::TopologyResponse)
        expect(response.brokers.size).to be > 0
        expect(response["clusterSize"]).to be > 0
      end

      it "can deploy a process definition" do # rubocop:disable RSpec/ExampleLength
        stub = credentials.grpc_stub

        resources = [
          Busybee::GRPC::Resource.new(
            name: File.basename(simple_bpmn_path),
            content: File.read(simple_bpmn_path)
          )
        ]

        request = Busybee::GRPC::DeployResourceRequest.new(
          resources: resources,
          tenantId: ""
        )

        response = stub.deploy_resource(request)

        expect(response.deployments.size).to be > 0
        deployment = response.deployments.first
        expect(deployment.process.bpmnProcessId).to eq("simple-process")
        expect(deployment.process.processDefinitionKey).to be > 0
      end
    end
  end
end
