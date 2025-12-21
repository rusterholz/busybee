# frozen_string_literal: true

RSpec.describe "Cancel Process Instance", :integration do
  # This test verifies that we can cancel running process instances
  # using the CancelProcessInstance GRPC operation.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }

  it "cancels a running process instance" do
    client = grpc_client

    # Deploy process and create instance
    deployment = deploy_process(client, bpmn_path)
    process_id = deployment[:process_id]
    instance_response = create_process_instance(client, process_id)
    process_instance_key = instance_response.processInstanceKey

    # Cancel the process instance
    request = Busybee::GRPC::CancelProcessInstanceRequest.new(
      processInstanceKey: process_instance_key
    )

    response = client.cancel_process_instance(request)

    # Verify the response is valid
    expect(response).to be_a(Busybee::GRPC::CancelProcessInstanceResponse)
  end

  it "handles errors when canceling non-existent process instance" do
    client = grpc_client

    # Try to cancel a process instance that doesn't exist
    request = Busybee::GRPC::CancelProcessInstanceRequest.new(
      processInstanceKey: 999_999_999 # Non-existent key
    )

    # Expect a GRPC error
    expect do
      client.cancel_process_instance(request)
    end.to raise_error(GRPC::NotFound)
  end
end
