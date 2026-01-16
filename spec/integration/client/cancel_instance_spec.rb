# frozen_string_literal: true

RSpec.describe Busybee::Client, "#cancel_instance" do
  let(:slow_bpmn_path) { File.expand_path("../../fixtures/slow_process.bpmn", __dir__) }

  shared_examples "cancel_instance" do
    before do
      # Deploy the slow process (waits 15 seconds before completing)
      client.deploy_process(slow_bpmn_path)
    end

    describe "successful cancellation" do
      it "cancels a running process instance and returns true" do
        process_instance_key = client.start_instance("slow-process")

        result = client.cancel_instance(process_instance_key)

        expect(result).to be(true)
      end

      it "accepts string keys and converts to integer" do
        process_instance_key = client.start_instance("slow-process")

        result = client.cancel_instance(process_instance_key.to_s)

        expect(result).to be(true)
      end
    end

    describe "error handling" do
      it "raises when instance does not exist" do
        non_existent_key = 999_999_999_999

        expect { client.cancel_instance(non_existent_key) }.to raise_error(Busybee::GRPC::Error) do |error|
          expect(error.cause).to be_a(GRPC::NotFound)
          expect(error.grpc_status).to eq(:not_found)
        end
      end

      it "returns false when instance not found and ignore_missing is true" do
        non_existent_key = 999_999_999_999

        result = client.cancel_instance(non_existent_key, ignore_missing: true)

        expect(result).to be(false)
      end

      it "returns false when canceling already cancelled instance with ignore_missing" do
        process_instance_key = client.start_instance("slow-process")
        client.cancel_instance(process_instance_key)

        # Second cancellation should return false with ignore_missing
        result = client.cancel_instance(process_instance_key, ignore_missing: true)

        expect(result).to be(false)
      end
    end

    describe "alias #cancel_process_instance" do
      it "works identically to #cancel_instance" do
        process_instance_key = client.start_instance("slow-process")

        result = client.cancel_process_instance(process_instance_key)

        expect(result).to be(true)
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

    it_behaves_like "cancel_instance"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "cancel_instance"
  end
end
