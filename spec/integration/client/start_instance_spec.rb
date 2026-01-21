# frozen_string_literal: true

RSpec.describe Busybee::Client, "#start_instance" do
  let(:simple_bpmn_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }

  shared_examples "start_instance" do
    before do
      # Deploy the process before starting instances
      @deployments = client.deploy_process(simple_bpmn_path)
    end

    describe "successful instance creation" do
      it "starts a process instance and returns the process_instance_key" do
        result = client.start_instance("simple-process")

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it "starts instance with variables" do
        result = client.start_instance("simple-process", vars: { orderId: 123, customer: "test" })

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it "starts instance with empty variables hash" do
        result = client.start_instance("simple-process", vars: {})

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it "starts instance with specific version" do
        result = client.start_instance("simple-process", version: 1)

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it "starts instance with :latest version explicitly" do
        result = client.start_instance("simple-process", version: :latest)

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it "starts instance with nil version (defaults to latest)" do
        result = client.start_instance("simple-process", version: nil)

        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end
    end

    describe "error handling" do
      it "raises when process does not exist" do
        expect { client.start_instance("non-existent-process") }.to raise_error(Busybee::GRPC::Error) do |error|
          expect(error.cause).to be_a(GRPC::NotFound)
          expect(error.grpc_status).to eq(:not_found)
        end
      end

      it "raises ArgumentError when vars is not a Hash" do
        expect do
          client.start_instance("simple-process", vars: "invalid")
        end.to raise_error(ArgumentError, "vars must be a Hash")
      end
    end

    describe "alias #start_process_instance" do
      it "works identically to #start_instance" do
        result = client.start_process_instance("simple-process")

        expect(result).to be_a(Integer)
        expect(result).to be > 0
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

    it_behaves_like "start_instance"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "start_instance"
  end
end
