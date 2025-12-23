# frozen_string_literal: true

require "json"

RSpec.describe "Set Variables", :integration do
  # This test verifies that we can set variables on running process instances
  # using the SetVariables GRPC operation.

  let(:bpmn_path) { File.expand_path("../fixtures/waiting_process.bpmn", __dir__) }
  let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }

  it "sets variables on a running process instance" do
    # Create instance and test set variables operation
    with_process_instance(process_id) do |process_instance_key|
      # Set variables on the process instance (this is what we're testing)
      variables = JSON.generate({
                                  newVar: "new_value",
                                  counter: 100,
                                  active: true
                                })

      request = Busybee::GRPC::SetVariablesRequest.new(
        elementInstanceKey: process_instance_key,
        variables: variables
      )

      response = grpc_client.set_variables(request)

      # Verify the response is valid
      expect(response).to be_a(Busybee::GRPC::SetVariablesResponse)
      expect(response.key).to be > 0
    end
  end

  it "handles errors when setting variables on non-existent process instance" do
    # Create and cancel a process instance
    with_process_instance(process_id) do |process_instance_key|
      # Cancel the instance
      cancel_request = Busybee::GRPC::CancelProcessInstanceRequest.new(
        processInstanceKey: process_instance_key
      )
      grpc_client.cancel_process_instance(cancel_request)

      # Now try to set variables on the canceled instance (this is what we're testing)
      variables = JSON.generate({ test: "value" })

      request = Busybee::GRPC::SetVariablesRequest.new(
        elementInstanceKey: process_instance_key,
        variables: variables
      )

      # Expect a GRPC error
      expect do
        grpc_client.set_variables(request)
      end.to raise_error(GRPC::NotFound)
    end
  end
end
