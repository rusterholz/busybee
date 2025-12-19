# frozen_string_literal: true

# Smoke test for GRPC protocol buffer generation
# This test will be removed in Phase 3 when real integration tests are added

RSpec.describe "GRPC Protocol Buffers" do
  it "can require the generated gateway_pb file" do
    expect { require "busybee/grpc/gateway_pb" }.not_to raise_error
  end

  it "can require the generated gateway_services_pb file" do
    expect { require "busybee/grpc/gateway_services_pb" }.not_to raise_error
  end

  it "defines classes in the Busybee::GRPC namespace" do
    require "busybee/grpc/gateway_pb"

    # Verify the namespace structure
    expect(defined?(Busybee::GRPC)).to be_truthy
    expect(defined?(Busybee::GRPC::TopologyRequest)).to be_truthy
  end

  it "can instantiate a TopologyRequest" do
    require "busybee/grpc/gateway_pb"

    # Instantiate a simple request class
    request = Busybee::GRPC::TopologyRequest.new

    # Verify it's the right class
    expect(request).to be_a(Busybee::GRPC::TopologyRequest)
    expect(request.class.name).to eq("Busybee::GRPC::TopologyRequest")
  end

  it "can instantiate an ActivateJobsRequest with fields" do
    require "busybee/grpc/gateway_pb"

    # Instantiate a more complex request with fields
    request = Busybee::GRPC::ActivateJobsRequest.new(
      type: "test-job",
      worker: "test-worker",
      timeout: 60_000,
      maxJobsToActivate: 10
    )

    # Verify fields are set correctly
    expect(request.type).to eq("test-job")
    expect(request.worker).to eq("test-worker")
    expect(request.timeout).to eq(60_000)
    expect(request.maxJobsToActivate).to eq(10)
  end

  it "defines the Gateway service stub" do
    require "busybee/grpc/gateway_services_pb"

    # Verify the service stub is defined
    expect(defined?(Busybee::GRPC::Gateway::Service)).to be_truthy
    expect(defined?(Busybee::GRPC::Gateway::Stub)).to be_truthy
  end
end
