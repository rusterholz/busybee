# frozen_string_literal: true

require "json"

RSpec.describe "GRPC Set Variables" do
  # This test verifies that we can set variables on running process instances
  # using the SetVariables GRPC operation.

  shared_context "with deployed waiting process" do
    let(:bpmn_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }
    let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  end

  shared_examples "set variables" do
    include_context "with deployed waiting process"

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

        response = client.set_variables(request)

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
        client.cancel_process_instance(cancel_request)

        # Now try to set variables on the canceled instance (this is what we're testing)
        variables = JSON.generate({ test: "value" })

        request = Busybee::GRPC::SetVariablesRequest.new(
          elementInstanceKey: process_instance_key,
          variables: variables
        )

        # Expect a GRPC error
        expect do
          client.set_variables(request)
        end.to raise_error(GRPC::NotFound)
      end
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

    it_behaves_like "set variables"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_grpc_stub }

    it_behaves_like "set variables"
  end
end
