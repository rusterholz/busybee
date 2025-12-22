# frozen_string_literal: true

require "busybee/testing/helpers"

RSpec.describe Busybee::Testing::Helpers do
  let(:test_class) do
    Class.new do
      include Busybee::Testing::Helpers
    end
  end
  let(:helper) { test_class.new }
  let(:mock_client) { instance_double(Busybee::GRPC::Gateway::Stub) }
  let(:bpmn_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }
  let(:bpmn_content) { File.read(bpmn_path) }

  before do
    allow(helper).to receive(:grpc_client).and_return(mock_client)
  end

  describe "#deploy_process" do
    let(:process_metadata) do
      double("ProcessMetadata", processDefinitionKey: 123, bpmnProcessId: "simple-process") # rubocop:disable RSpec/VerifiedDoubles
    end
    let(:deploy_response) do
      double( # rubocop:disable RSpec/VerifiedDoubles
        "DeployResponse",
        deployments: [
          double("Deployment", process: process_metadata) # rubocop:disable RSpec/VerifiedDoubles
        ]
      )
    end

    before do
      allow(mock_client).to receive(:deploy_resource).and_return(deploy_response)
    end

    context "when deploying as-is (default)" do
      it "deploys the BPMN file without modification" do
        expect(mock_client).to receive(:deploy_resource) do |request|
          expect(request).to be_an_instance_of(Busybee::GRPC::DeployResourceRequest)
          expect(request.resources.first.content).to eq(bpmn_content)
          deploy_response
        end
        helper.deploy_process(bpmn_path)
      end

      it "returns deployment info with original process_id" do
        result = helper.deploy_process(bpmn_path)
        expect(result[:process]).not_to be_nil
        expect(result[:process_id]).to eq("simple-process")
      end
    end

    context "when uniquify: true" do
      it "generates a unique process_id" do
        result = helper.deploy_process(bpmn_path, uniquify: true)
        expect(result[:process_id]).to match(/^test-process-[a-f0-9]{12}$/)
        expect(result[:process]).not_to be_nil
      end

      it "modifies BPMN content with unique ID" do
        expect(mock_client).to receive(:deploy_resource) do |request|
          content = request.resources.first.content
          expect(content).not_to eq(bpmn_content)
          expect(content).to match(/<bpmn:process id="test-process-[a-f0-9]{12}"/)
          deploy_response
        end
        helper.deploy_process(bpmn_path, uniquify: true)
      end
    end

    context "when uniquify: custom-id" do
      it "uses the provided process_id" do
        result = helper.deploy_process(bpmn_path, uniquify: "my-custom-id")
        expect(result[:process_id]).to eq("my-custom-id")
        expect(result[:process]).not_to be_nil
      end

      it "modifies BPMN content with custom ID" do
        expect(mock_client).to receive(:deploy_resource) do |request|
          content = request.resources.first.content
          expect(content).not_to eq(bpmn_content)
          expect(content).to include('<bpmn:process id="my-custom-id"')
          deploy_response
        end
        helper.deploy_process(bpmn_path, uniquify: "my-custom-id")
      end
    end
  end
end
