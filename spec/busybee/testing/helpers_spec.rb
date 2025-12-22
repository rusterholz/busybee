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

  describe "#with_process_instance" do
    let(:create_response) do
      double("CreateResponse", processInstanceKey: 98_765) # rubocop:disable RSpec/VerifiedDoubles
    end

    before do
      allow(mock_client).to receive(:create_process_instance).and_return(create_response)
      allow(mock_client).to receive(:cancel_process_instance)
    end

    it "creates a process instance and yields the key" do
      expect(mock_client).to receive(:create_process_instance)

      yielded_key = nil
      helper.with_process_instance("my-process") do |key|
        yielded_key = key
      end

      expect(yielded_key).to eq(98_765)
    end

    it "passes variables to the process instance" do
      expect(mock_client).to receive(:create_process_instance) do |request|
        expect(JSON.parse(request.variables)).to eq("foo" => "bar")
        create_response
      end

      helper.with_process_instance("my-process", foo: "bar") { |_| } # rubocop:disable Lint/EmptyBlock
    end

    it "cancels the process instance after the block" do
      expect(mock_client).to receive(:cancel_process_instance).with(
        an_instance_of(Busybee::GRPC::CancelProcessInstanceRequest)
      )

      helper.with_process_instance("my-process") { |_| } # rubocop:disable Lint/EmptyBlock
    end

    it "cancels even if block raises" do
      expect(mock_client).to receive(:cancel_process_instance)

      expect do
        helper.with_process_instance("my-process") { raise "oops" }
      end.to raise_error("oops")
    end

    it "ignores NotFound when canceling completed process" do
      allow(mock_client).to receive(:cancel_process_instance).and_raise(GRPC::NotFound)

      expect do
        helper.with_process_instance("my-process") { |_| } # rubocop:disable Lint/EmptyBlock
      end.not_to raise_error
    end
  end

  describe "#process_instance_key" do
    let(:create_response) { double("CreateResponse", processInstanceKey: 11_111) } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(mock_client).to receive(:create_process_instance).and_return(create_response)
      allow(mock_client).to receive(:cancel_process_instance)
    end

    it "returns the current process instance key inside the block" do
      helper.with_process_instance("my-process") do |_|
        expect(helper.process_instance_key).to eq(11_111)
      end
    end
  end

  describe "#activate_job" do
    # Using plain doubles for protobuf response classes since they're dynamically generated
    # rubocop:disable RSpec/VerifiedDoubles
    let(:raw_job) do
      double(
        "Busybee::GRPC::ActivatedJob",
        key: 555,
        processInstanceKey: 98_765,
        variables: "{}",
        customHeaders: "{}",
        retries: 3
      )
    end
    let(:activate_response) { double("Busybee::GRPC::ActivateJobsResponse", jobs: [raw_job]) }
    # rubocop:enable RSpec/VerifiedDoubles

    before do
      allow(mock_client).to receive(:activate_jobs).and_return([activate_response])
    end

    it "returns an ActivatedJob" do
      result = helper.activate_job("my-task")
      expect(result).to be_a(Busybee::Testing::ActivatedJob)
      expect(result.key).to eq(555)
    end

    it "raises when no job is found" do
      empty_response = double("Busybee::GRPC::ActivateJobsResponse", jobs: []) # rubocop:disable RSpec/VerifiedDoubles
      allow(mock_client).to receive(:activate_jobs).and_return([empty_response])

      expect do
        helper.activate_job("missing-task")
      end.to raise_error(Busybee::Testing::NoJobAvailable, /No job of type 'missing-task' available/)
    end
  end

  describe "#activate_jobs" do
    # Using plain doubles for protobuf response classes since they're dynamically generated
    # rubocop:disable RSpec/VerifiedDoubles
    let(:raw_jobs) do
      [
        double("Busybee::GRPC::ActivatedJob", key: 1, processInstanceKey: 100, variables: "{}", customHeaders: "{}",
                                              retries: 3),
        double("Busybee::GRPC::ActivatedJob", key: 2, processInstanceKey: 100, variables: "{}", customHeaders: "{}",
                                              retries: 3)
      ]
    end
    let(:activate_response) { double("Busybee::GRPC::ActivateJobsResponse", jobs: raw_jobs) }
    # rubocop:enable RSpec/VerifiedDoubles

    before do
      allow(mock_client).to receive(:activate_jobs).and_return([activate_response])
    end

    it "returns an Enumerator of ActivatedJob" do
      result = helper.activate_jobs("my-task", max_jobs: 2)
      expect(result).to be_an(Enumerator)

      jobs = result.to_a
      expect(jobs.length).to eq(2)
      expect(jobs.first).to be_a(Busybee::Testing::ActivatedJob)
    end
  end
end
