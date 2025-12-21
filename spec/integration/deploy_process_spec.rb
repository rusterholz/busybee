# frozen_string_literal: true

RSpec.describe "Deploy Process", :integration do
  # This test verifies that we can deploy BPMN process definitions to Zeebe
  # using the DeployResource endpoint. Each deployment receives a unique key
  # and returns metadata about the deployed process.

  let(:bpmn_path) { File.expand_path("../fixtures/simple_process.bpmn", __dir__) }
  let(:bpmn_content) { File.read(bpmn_path) }

  it "deploys a BPMN process to Zeebe" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    # Create a GRPC client connection to Zeebe
    client = grpc_client

    # Create a resource object for the BPMN file
    resource = Busybee::GRPC::Resource.new(
      name: "simple_process.bpmn",
      content: bpmn_content
    )

    # Create a deploy resource request
    request = Busybee::GRPC::DeployResourceRequest.new(
      resources: [resource]
    )

    # Deploy the process to Zeebe (no auth needed with unprotectedApi: true)
    response = client.deploy_resource(request)

    # Verify the deployment was successful
    expect(response).to be_a(Busybee::GRPC::DeployResourceResponse)
    expect(response.key).to be > 0

    # Verify we received deployment metadata
    expect(response.deployments).not_to be_empty
    deployment = response.deployments.first

    # The deployment should contain process metadata
    expect(deployment.process).not_to be_nil
    process = deployment.process

    expect(process.bpmnProcessId).to eq("simple-process")
    expect(process.version).to be > 0
    expect(process.processDefinitionKey).to be > 0
    expect(process.resourceName).to eq("simple_process.bpmn")
  end

  it "deduplicates identical deployments (Camunda 8.8+)" do # rubocop:disable RSpec/ExampleLength
    # In Camunda 8.8+, deploying identical BPMN content is deduplicated
    # (see https://github.com/camunda/camunda/issues/26239)
    # Deployment keys are still unique, but process version stays the same
    client = grpc_client

    resource = Busybee::GRPC::Resource.new(
      name: "simple_process.bpmn",
      content: bpmn_content
    )

    request = Busybee::GRPC::DeployResourceRequest.new(
      resources: [resource]
    )

    # First deployment
    response1 = client.deploy_resource(request)
    deployment_key1 = response1.key

    # Second deployment (identical content)
    response2 = client.deploy_resource(request)
    deployment_key2 = response2.key

    # Deployment keys should still be unique
    expect(deployment_key1).to be > 0
    expect(deployment_key2).to be > 0
    expect(deployment_key2).to be > deployment_key1

    # But process versions should be the same (deduplication)
    process1 = response1.deployments.first.process
    process2 = response2.deployments.first.process

    expect(process2.version).to eq(process1.version) # Same version for identical content
    expect(process1.bpmnProcessId).to eq(process2.bpmnProcessId)
  end

  it "handles deployment errors gracefully" do
    # Try to deploy invalid BPMN content
    client = grpc_client

    resource = Busybee::GRPC::Resource.new(
      name: "invalid.bpmn",
      content: "not valid BPMN content"
    )

    request = Busybee::GRPC::DeployResourceRequest.new(
      resources: [resource]
    )

    # Expect a GRPC error when deploying invalid content
    expect do
      client.deploy_resource(request)
    end.to raise_error(GRPC::InvalidArgument)
  end
end
