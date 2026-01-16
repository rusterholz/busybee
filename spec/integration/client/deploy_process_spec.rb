# frozen_string_literal: true

RSpec.describe Busybee::Client, "#deploy_process" do
  let(:simple_bpmn_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }
  let(:waiting_bpmn_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }

  shared_examples "deploy_process" do
    describe "successful deployments" do
      it "deploys a BPMN file to Zeebe" do
        result = client.deploy_process(simple_bpmn_path)

        expect(result).to be_a(Hash)
        expect(result.keys).to all(be_a(String))
        expect(result.values).to all(be_a(Integer))

        # Verify we got a valid process ID and key
        process_id = result.keys.first
        definition_key = result.values.first

        expect(process_id).to eq("simple-process")
        expect(definition_key).to be > 0
      end

      it "deploys multiple BPMN files at once" do
        result = client.deploy_process(simple_bpmn_path, waiting_bpmn_path)

        expect(result).to be_a(Hash)
        expect(result.size).to eq(2)

        # Both processes should be deployed
        expect(result).to include("simple-process")
        expect(result).to include("waiting-process")

        # Both should have valid definition keys
        expect(result["simple-process"]).to be > 0
        expect(result["waiting-process"]).to be > 0
      end
    end

    describe "error handling" do
      it "raises Errno::ENOENT when file does not exist" do
        expect do
          client.deploy_process("nonexistent.bpmn")
        end.to raise_error(Errno::ENOENT, /No such file or directory/)
      end

      it "wraps GRPC errors when deploying invalid BPMN" do
        Tempfile.create(["invalid", ".bpmn"]) do |file|
          file.write("not valid BPMN content")
          file.close

          expect do
            client.deploy_process(file.path)
          end.to raise_error(Busybee::GRPC::Error) do |error| # rubocop:disable Style/MultilineBlockChain
            # Should wrap the original GRPC error
            expect(error.cause).to be_a(GRPC::InvalidArgument)
            expect(error.grpc_status).to eq(:invalid_argument)

            # Should include context in message
            expect(error.message).to include("GRPC call failed")
          end
        end
      end

      it "wraps GRPC errors when tenant_id is provided but multi-tenancy is disabled", :single_tenant_only do
        expect do
          client.deploy_process(simple_bpmn_path, tenant_id: "acme-production")
        end.to raise_error(Busybee::GRPC::Error) do |error| # rubocop:disable Style/MultilineBlockChain
          # Should wrap the GRPC InvalidArgument error
          expect(error.cause).to be_a(GRPC::InvalidArgument)
          expect(error.grpc_status).to eq(:invalid_argument)

          # Should include multi-tenancy error in details
          expect(error.message).to include("multi-tenancy is disabled")
        end
      end

      # Multi-tenancy requires Camunda Identity service for tenant authorization.
      # Local dev environment uses insecure mode without Identity.
      # See: https://docs.camunda.io/docs/self-managed/operational-guides/configure-multi-tenancy/
      it "deploys with tenant_id when multi-tenancy is enabled", :multi_tenant_only do
        skip "Requires Camunda Identity service"
        result = client.deploy_process(simple_bpmn_path, tenant_id: "acme-production")

        expect(result).to be_a(Hash)
        expect(result["simple-process"]).to be > 0
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

    it_behaves_like "deploy_process"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "deploy_process"
  end
end
