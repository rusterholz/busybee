# frozen_string_literal: true

require "json"

RSpec.describe "Create Process Instance", :integration do
  # This test verifies that we can create and start process instances
  # after deploying a process definition. Process instances execute
  # the workflow logic and maintain their own state.

  let(:bpmn_path) { File.expand_path("../fixtures/simple_process.bpmn", __dir__) }

  # Helper method to deploy the simple process with a unique ID before creating instances
  # This ensures test isolation - each test gets its own process definition
  def deploy_simple_process(client, process_id = nil) # rubocop:disable Metrics/MethodLength
    process_id ||= unique_process_id
    bpmn_content = bpmn_with_unique_id(bpmn_path, process_id)

    resource = Busybee::GRPC::Resource.new(
      name: "simple_process.bpmn",
      content: bpmn_content
    )

    request = Busybee::GRPC::DeployResourceRequest.new(
      resources: [resource]
    )

    response = client.deploy_resource(request)
    {
      process: response.deployments.first.process,
      process_id: process_id
    }
  end

  it "creates a process instance from a deployed process" do
    client = grpc_client

    # Deploy the process first
    deployment = deploy_simple_process(client)
    process_metadata = deployment[:process]
    process_id = deployment[:process_id]
    process_definition_key = process_metadata.processDefinitionKey

    # Create a process instance using the process definition key
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )

    response = client.create_process_instance(request)

    # Verify the instance was created successfully
    expect(response).to be_a(Busybee::GRPC::CreateProcessInstanceResponse)
    expect(response.processInstanceKey).to be > 0
    expect(response.processDefinitionKey).to eq(process_definition_key)
    expect(response.bpmnProcessId).to eq(process_id)
    expect(response.version).to be > 0
  end

  it "creates a process instance using bpmnProcessId" do
    client = grpc_client

    # Deploy the process first
    deployment = deploy_simple_process(client)
    deployment[:process]
    expected_process_id = deployment[:process_id]

    # Create a process instance using the bpmnProcessId
    # version: -1 means "use the latest version"
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: expected_process_id,
      version: -1
    )

    response = client.create_process_instance(request)

    # Verify the instance was created successfully and response contains expected metadata
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(expected_process_id)
    expect(response.version).to be > 0
  end

  it "creates a process instance with variables" do # rubocop:disable RSpec/ExampleLength
    client = grpc_client

    # Deploy the process first
    deployment = deploy_simple_process(client)
    deployment[:process].processDefinitionKey
    process_id = deployment[:process_id]

    # Create process instance with JSON variables
    variables = JSON.generate({
                                testVar: "test_value",
                                number: 42,
                                flag: true
                              })

    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: process_id,
      version: -1,
      variables: variables
    )

    response = client.create_process_instance(request)

    # Verify the instance was created successfully
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(process_id)
  end

  it "creates multiple unique process instances" do
    client = grpc_client

    # Deploy the process first
    deployment = deploy_simple_process(client)
    process_definition_key = deployment[:process].processDefinitionKey

    # Create first process instance
    request1 = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )
    response1 = client.create_process_instance(request1)

    # Create second process instance
    request2 = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )
    response2 = client.create_process_instance(request2)

    # Each instance should have a unique key
    expect(response1.processInstanceKey).to be > 0
    expect(response2.processInstanceKey).to be > 0
    expect(response1.processInstanceKey).not_to eq(response2.processInstanceKey)

    # But they should reference the same process definition
    expect(response1.processDefinitionKey).to eq(response2.processDefinitionKey)
  end

  it "handles errors when creating instance for non-existent process" do
    client = grpc_client

    # Try to create an instance for a process that doesn't exist
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: "non-existent-process"
    )

    # Expect a GRPC error
    expect do
      client.create_process_instance(request)
    end.to raise_error(GRPC::NotFound)
  end

  it "creates a process instance with result (synchronous)" do # rubocop:disable RSpec/ExampleLength
    client = grpc_client

    # Deploy the process first
    deployment = deploy_simple_process(client)
    process_id = deployment[:process_id]

    # Create a process instance and wait for it to complete
    # The simple process completes immediately (just start -> end)
    inner_request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: process_id,
      version: -1
    )

    request = Busybee::GRPC::CreateProcessInstanceWithResultRequest.new(
      request: inner_request,
      requestTimeout: 10_000 # 10 seconds
    )

    response = client.create_process_instance_with_result(request)

    # Verify the instance was created and completed
    expect(response).to be_a(Busybee::GRPC::CreateProcessInstanceWithResultResponse)
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(process_id)
    expect(response.processDefinitionKey).to be > 0
  end
end
