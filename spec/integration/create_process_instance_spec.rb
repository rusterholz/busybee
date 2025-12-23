# frozen_string_literal: true

require "json"

RSpec.describe "Create Process Instance", :integration do
  # This test verifies that we can create and start process instances
  # after deploying a process definition. Process instances execute
  # the workflow logic and maintain their own state.

  let(:bpmn_path) { File.expand_path("../fixtures/simple_process.bpmn", __dir__) }
  let(:deployment) { deploy_process(bpmn_path, uniquify: true) }
  let(:process_id) { deployment[:process_id] }
  let(:process_definition_key) { deployment[:process].processDefinitionKey }

  it "creates a process instance from a deployed process" do
    # Create a process instance using the process definition key (this is what we're testing)
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )

    response = grpc_client.create_process_instance(request)

    # Verify the instance was created successfully
    expect(response).to be_a(Busybee::GRPC::CreateProcessInstanceResponse)
    expect(response.processInstanceKey).to be > 0
    expect(response.processDefinitionKey).to eq(process_definition_key)
    expect(response.bpmnProcessId).to eq(process_id)
    expect(response.version).to be > 0
  end

  it "creates a process instance using bpmnProcessId" do
    # Create a process instance using the bpmnProcessId (this is what we're testing)
    # version: -1 means "use the latest version"
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: process_id,
      version: -1
    )

    response = grpc_client.create_process_instance(request)

    # Verify the instance was created successfully and response contains expected metadata
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(process_id)
    expect(response.version).to be > 0
  end

  it "creates a process instance with variables" do
    # Create process instance with JSON variables (this is what we're testing)
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

    response = grpc_client.create_process_instance(request)

    # Verify the instance was created successfully
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(process_id)
  end

  it "creates multiple unique process instances" do
    # Create first process instance (this is what we're testing)
    request1 = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )
    response1 = grpc_client.create_process_instance(request1)

    # Create second process instance
    request2 = Busybee::GRPC::CreateProcessInstanceRequest.new(
      processDefinitionKey: process_definition_key
    )
    response2 = grpc_client.create_process_instance(request2)

    # Each instance should have a unique key
    expect(response1.processInstanceKey).to be > 0
    expect(response2.processInstanceKey).to be > 0
    expect(response1.processInstanceKey).not_to eq(response2.processInstanceKey)

    # But they should reference the same process definition
    expect(response1.processDefinitionKey).to eq(response2.processDefinitionKey)
  end

  it "handles errors when creating instance for non-existent process" do
    # Try to create an instance for a process that doesn't exist (this is what we're testing)
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: "non-existent-process"
    )

    # Expect a GRPC error
    expect do
      grpc_client.create_process_instance(request)
    end.to raise_error(GRPC::NotFound)
  end

  it "creates a process instance with result (synchronous)" do
    # Create a process instance and wait for it to complete (this is what we're testing)
    # The simple process completes immediately (just start -> end)
    inner_request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: process_id,
      version: -1
    )

    request = Busybee::GRPC::CreateProcessInstanceWithResultRequest.new(
      request: inner_request,
      requestTimeout: 10_000 # 10 seconds
    )

    response = grpc_client.create_process_instance_with_result(request)

    # Verify the instance was created and completed
    expect(response).to be_a(Busybee::GRPC::CreateProcessInstanceWithResultResponse)
    expect(response.processInstanceKey).to be > 0
    expect(response.bpmnProcessId).to eq(process_id)
    expect(response.processDefinitionKey).to be > 0
  end
end
