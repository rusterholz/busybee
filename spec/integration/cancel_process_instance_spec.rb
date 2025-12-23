# frozen_string_literal: true

RSpec.describe "Cancel Process Instance", :integration do
  # This test verifies that we can cancel running process instances
  # using the CancelProcessInstance GRPC operation.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }
  let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }

  it "cancels a running process instance" do
    # Create instance and test cancel operation
    with_process_instance(process_id) do |process_instance_key|
      # Cancel the process instance (this is what we're testing)
      request = Busybee::GRPC::CancelProcessInstanceRequest.new(
        processInstanceKey: process_instance_key
      )

      response = grpc_client.cancel_process_instance(request)

      # Verify the response is valid
      expect(response).to be_a(Busybee::GRPC::CancelProcessInstanceResponse)
    end
  end

  it "handles errors when canceling non-existent process instance" do
    # Try to cancel a process instance that doesn't exist
    request = Busybee::GRPC::CancelProcessInstanceRequest.new(
      processInstanceKey: 999_999_999 # Non-existent key
    )

    # Expect a GRPC error
    expect do
      grpc_client.cancel_process_instance(request)
    end.to raise_error(GRPC::NotFound)
  end
end
