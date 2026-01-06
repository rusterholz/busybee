# frozen_string_literal: true

require "spec_helper"
require "busybee/client"

RSpec.describe Busybee::Client, "#deploy_process" do # rubocop:disable RSpec/SpecFilePathFormat
  let(:client) { described_class.new(insecure: true, cluster_address: "localhost:26500") }
  let(:stub) { instance_double(Busybee::GRPC::Gateway::Stub) }
  let(:simple_process_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }
  let(:waiting_process_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }

  before { allow(client.credentials).to receive(:grpc_stub).and_return(stub) }

  it "deploys a BPMN file and returns process_id => key hash" do
    response = double(
      deployments: [
        double(process: double(bpmnProcessId: "simple-process", processDefinitionKey: 12345))
      ]
    )
    allow(stub).to receive(:deploy_resource).and_return(response)

    result = client.deploy_process(simple_process_path)
    expect(result).to eq({ "simple-process" => 12345 })
  end

  it "supports multiple paths" do
    response = double(
      deployments: [
        double(process: double(bpmnProcessId: "simple-process", processDefinitionKey: 111)),
        double(process: double(bpmnProcessId: "waiting-process", processDefinitionKey: 222))
      ]
    )
    allow(stub).to receive(:deploy_resource).and_return(response)

    result = client.deploy_process(simple_process_path, waiting_process_path)
    expect(result).to eq({ "simple-process" => 111, "waiting-process" => 222 })
  end

  it "returns latest deployment when same process_id deployed multiple times" do
    response = double(
      deployments: [
        double(process: double(bpmnProcessId: "simple-process", processDefinitionKey: 111)),
        double(process: double(bpmnProcessId: "simple-process", processDefinitionKey: 222))
      ]
    )
    allow(stub).to receive(:deploy_resource).and_return(response)

    result = client.deploy_process(simple_process_path, simple_process_path)
    expect(result).to eq({ "simple-process" => 222 }) # Later deployment overwrites in hash
  end

  it "supports tenant_id" do
    response = double(deployments: [])
    allow(stub).to receive(:deploy_resource).with(
      having_attributes(tenantId: "tenant-a")
    ).and_return(response)

    client.deploy_process(simple_process_path, tenant_id: "tenant-a")

    expect(stub).to have_received(:deploy_resource).with(having_attributes(tenantId: "tenant-a"))
  end

  it "wraps GRPC errors in Busybee::GRPC::Error" do
    allow(stub).to receive(:deploy_resource).and_raise(GRPC::NotFound.new("process not found"))

    expect { client.deploy_process(simple_process_path) }.to raise_error(Busybee::GRPC::Error)

    begin
      client.deploy_process(simple_process_path)
    rescue Busybee::GRPC::Error => e
      expect(e.cause).to be_a(GRPC::NotFound)
      expect(e.grpc_status).to eq(:not_found)
    end
  end
end
