# frozen_string_literal: true

RSpec.describe "GRPC Topology" do
  # This test verifies that we can successfully connect to a Zeebe cluster
  # and retrieve cluster topology information including brokers, partitions,
  # and cluster configuration.

  shared_examples "topology retrieval" do
    it "retrieves cluster topology information" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
      # Create a topology request (empty message)
      request = Busybee::GRPC::TopologyRequest.new

      # Call the topology endpoint
      response = client.topology(request)

      # Verify the response contains cluster information
      expect(response).to be_a(Busybee::GRPC::TopologyResponse)
      expect(response.clusterSize).to be > 0
      expect(response.partitionsCount).to be > 0
      expect(response.replicationFactor).to be > 0
      expect(response.gatewayVersion).not_to be_empty

      # Verify we have broker information
      expect(response.brokers).not_to be_empty
      broker = response.brokers.first
      expect(broker.nodeId).to be >= 0
      expect(broker.host).not_to be_empty
      expect(broker.port).to be > 0
      expect(broker.partitions).not_to be_empty

      # Verify partition information
      partition = broker.partitions.first
      expect(partition.partitionId).to be >= 1
      expect(partition.role).to be_a(Symbol)
      expect(partition.health).to be_a(Symbol)
    end

    it "connects using the generated GRPC classes directly" do
      # This test verifies that we're using the generated GRPC classes
      # without any wrapper layer

      # Verify the client is the correct stub class
      expect(client).to be_a(Busybee::GRPC::Gateway::Stub)

      # Verify request/response classes are in the correct namespace
      request = Busybee::GRPC::TopologyRequest.new
      expect(request.class.name).to eq("Busybee::GRPC::TopologyRequest")

      response = client.topology(request)
      expect(response.class.name).to eq("Busybee::GRPC::TopologyResponse")
    end
  end

  context "with local Zeebe", :integration do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :insecure
      example.run
      Busybee.credential_type = original
    end

    let(:client) { local_grpc_stub }

    it_behaves_like "topology retrieval"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_grpc_stub }

    it_behaves_like "topology retrieval"
  end
end
