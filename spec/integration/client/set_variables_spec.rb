# frozen_string_literal: true

RSpec.describe Busybee::Client, "#set_variables" do
  shared_context "with deployed waiting process" do
    let(:bpmn_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }
    let(:process_id) { deploy_process(bpmn_path, uniquify: true)[:process_id] }
  end

  shared_examples "set_variables" do
    include_context "with deployed waiting process"

    it "sets variables on a running process instance" do
      # Create instance and test set variables operation
      with_process_instance(process_id, initialVar: "initial_value") do |process_instance_key|
        # Set variables on the process instance
        key = client.set_variables(process_instance_key,
                                   vars: { newVar: "new_value", counter: 100, active: true })

        # Verify the operation key was returned
        expect(key).to be_a(Integer)
        expect(key).to be > 0
      end
    end

    it "sets variables with local scope" do
      with_process_instance(process_id) do |process_instance_key|
        # Set local variables (not propagated to parent scopes)
        key = client.set_variables(process_instance_key,
                                   vars: { localVar: "local_value" },
                                   local: true)

        expect(key).to be > 0
      end
    end

    it "sets variables with empty hash" do
      with_process_instance(process_id) do |process_instance_key|
        # Setting empty variables should succeed (no-op)
        key = client.set_variables(process_instance_key, vars: {})

        expect(key).to be > 0
      end
    end

    it "handles errors when setting variables on cancelled process instance" do
      with_process_instance(process_id) do |process_instance_key|
        # Cancel the instance
        client.cancel_instance(process_instance_key)

        # Try to set variables on the cancelled instance
        expect { client.set_variables(process_instance_key, vars: { test: "value" }) }.
          to raise_error(Busybee::GRPC::Error) do |error|
            expect(error.cause).to be_a(GRPC::NotFound)
            expect(error.grpc_status).to eq(:not_found)
          end
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

    let(:client) { local_busybee_client }

    it_behaves_like "set_variables"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "set_variables"
  end
end
