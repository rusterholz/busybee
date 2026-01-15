# frozen_string_literal: true

RSpec.describe "GRPC Cancel Process Instance" do
  # This test verifies that we can cancel running process instances
  # using the CancelProcessInstance GRPC operation.

  shared_context "with deployed waiting process" do
    let(:bpmn_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }
    let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  end

  shared_examples "cancel process instance" do
    include_context "with deployed waiting process"

    it "cancels a running process instance" do
      # Create instance and test cancel operation
      with_process_instance(process_id) do |process_instance_key|
        # Cancel the process instance (this is what we're testing)
        request = Busybee::GRPC::CancelProcessInstanceRequest.new(
          processInstanceKey: process_instance_key
        )

        response = client.cancel_process_instance(request)

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
        client.cancel_process_instance(request)
      end.to raise_error(GRPC::NotFound)
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

    it_behaves_like "cancel process instance"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_grpc_stub }

    it_behaves_like "cancel process instance"
  end
end
