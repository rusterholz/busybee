# frozen_string_literal: true

RSpec.describe "Zeebe Topology", :integration do
  # This test verifies that we can successfully connect to a Zeebe cluster
  # and retrieve cluster topology information including brokers, partitions,
  # and cluster configuration.

  it "retrieves cluster topology information" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    # Create a GRPC client connection to Zeebe
    client = grpc_client

    # Create a topology request (empty message)
    request = Busybee::GRPC::TopologyRequest.new

    # Call the topology endpoint (no auth needed with unprotectedApi: true)
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

    client = grpc_client

    # Verify the client is the correct stub class
    expect(client).to be_a(Busybee::GRPC::Gateway::Stub)

    # Verify request/response classes are in the correct namespace
    request = Busybee::GRPC::TopologyRequest.new
    expect(request.class.name).to eq("Busybee::GRPC::TopologyRequest")

    response = client.topology(request)
    expect(response.class.name).to eq("Busybee::GRPC::TopologyResponse")
  end
end
