# frozen_string_literal: true

require "json"

RSpec.describe "Set Variables", :integration do
  # This test verifies that we can set variables on running process instances
  # using the SetVariables GRPC operation.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }

  it "sets variables on a running process instance" do
    client = grpc_client

    # Deploy process and create instance
    deployment = deploy_process(client, bpmn_path)
    process_id = deployment[:process_id]
    instance_response = create_process_instance(client, process_id)
    process_instance_key = instance_response.processInstanceKey

    # Set variables on the process instance
    variables = JSON.generate({
      newVar: "new_value",
      counter: 100,
      active: true
    })

    request = Busybee::GRPC::SetVariablesRequest.new(
      elementInstanceKey: process_instance_key,
      variables: variables
    )

    response = client.set_variables(request)

    # Verify the response is valid
    expect(response).to be_a(Busybee::GRPC::SetVariablesResponse)
    expect(response.key).to be > 0
  end

  it "handles errors when setting variables on non-existent process instance" do
    client = grpc_client

    # Create and then cancel a process instance
    deployment = deploy_process(client, bpmn_path)
    process_id = deployment[:process_id]
    instance_response = create_process_instance(client, process_id)
    process_instance_key = instance_response.processInstanceKey

    # Cancel the instance
    cancel_request = Busybee::GRPC::CancelProcessInstanceRequest.new(
      processInstanceKey: process_instance_key
    )
    client.cancel_process_instance(cancel_request)

    # Now try to set variables on the canceled instance
    variables = JSON.generate({ test: "value" })

    request = Busybee::GRPC::SetVariablesRequest.new(
      elementInstanceKey: process_instance_key,
      variables: variables
    )

    # Expect a GRPC error
    expect {
      client.set_variables(request)
    }.to raise_error(GRPC::NotFound)
  end
end
