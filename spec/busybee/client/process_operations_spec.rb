# frozen_string_literal: true

require "busybee/client"

RSpec.describe Busybee::Client::ProcessOperations do
  let(:client) { Busybee::Client.new(insecure: true, cluster_address: "localhost:26500") }
  let(:stub) { instance_double(Busybee::GRPC::Gateway::Stub) }

  before { allow(client.credentials).to receive(:grpc_stub).and_return(stub) }

  describe "#deploy_process" do
    let(:simple_process_path) { File.expand_path("../../fixtures/simple_process.bpmn", __dir__) }
    let(:waiting_process_path) { File.expand_path("../../fixtures/waiting_process.bpmn", __dir__) }

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

  describe "#start_instance" do
    it "starts a process instance and returns the process_instance_key" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).and_return(response)

      result = client.start_instance("order-fulfillment")
      expect(result).to eq(67890)
    end

    it "supports variables" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).with(
        having_attributes(variables: '{"orderId":123}')
      ).and_return(response)

      client.start_instance("order-fulfillment", vars: { orderId: 123 })

      expect(stub).to have_received(:create_process_instance).with(
        having_attributes(variables: '{"orderId":123}')
      )
    end

    it "defaults to latest version" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).with(
        having_attributes(version: -1)
      ).and_return(response)

      client.start_instance("order-fulfillment")

      expect(stub).to have_received(:create_process_instance).with(
        having_attributes(version: -1)
      )
    end

    it "supports explicit :latest version" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).with(
        having_attributes(version: -1)
      ).and_return(response)

      client.start_instance("order-fulfillment", version: :latest)

      expect(stub).to have_received(:create_process_instance).with(
        having_attributes(version: -1)
      )
    end

    it "supports specific version number" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).with(
        having_attributes(version: 5)
      ).and_return(response)

      client.start_instance("order-fulfillment", version: 5)

      expect(stub).to have_received(:create_process_instance).with(
        having_attributes(version: 5)
      )
    end

    it "supports tenant_id" do
      response = double(processInstanceKey: 67890)
      allow(stub).to receive(:create_process_instance).with(
        having_attributes(tenantId: "tenant-a")
      ).and_return(response)

      client.start_instance("order-fulfillment", tenant_id: "tenant-a")

      expect(stub).to have_received(:create_process_instance).with(
        having_attributes(tenantId: "tenant-a")
      )
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:create_process_instance).and_raise(GRPC::NotFound.new("process not found"))

      expect { client.start_instance("unknown-process") }.to raise_error(Busybee::GRPC::Error)

      begin
        client.start_instance("unknown-process")
      rescue Busybee::GRPC::Error => e
        expect(e.cause).to be_a(GRPC::NotFound)
        expect(e.grpc_status).to eq(:not_found)
      end
    end
  end

  describe "#start_process_instance" do
    it "is aliased to #start_instance" do
      expect(client.method(:start_process_instance)).to eq(client.method(:start_instance))
    end
  end

  describe "#cancel_instance" do
    it "cancels a process instance and returns true" do
      response = double
      allow(stub).to receive(:cancel_process_instance).and_return(response)

      result = client.cancel_instance(67890)
      expect(result).to be(true)
    end

    it "accepts string keys and converts to integer" do
      response = double
      allow(stub).to receive(:cancel_process_instance).with(
        having_attributes(processInstanceKey: 67890)
      ).and_return(response)

      client.cancel_instance("67890")

      expect(stub).to have_received(:cancel_process_instance).with(
        having_attributes(processInstanceKey: 67890)
      )
    end

    it "raises when instance not found by default" do
      allow(stub).to receive(:cancel_process_instance).and_raise(GRPC::NotFound.new("not found"))

      expect { client.cancel_instance(99999) }.to raise_error(Busybee::GRPC::Error)
    end

    it "returns false when instance not found and ignore_missing is true" do
      allow(stub).to receive(:cancel_process_instance).and_raise(GRPC::NotFound.new("not found"))

      result = client.cancel_instance(99999, ignore_missing: true)
      expect(result).to be(false)
    end

    it "wraps other GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:cancel_process_instance).and_raise(GRPC::Internal.new("internal error"))

      expect { client.cancel_instance(67890) }.to raise_error(Busybee::GRPC::Error)

      begin
        client.cancel_instance(67890)
      rescue Busybee::GRPC::Error => e
        expect(e.cause).to be_a(GRPC::Internal)
        expect(e.grpc_status).to eq(:internal)
      end
    end
  end

  describe "#cancel_process_instance" do
    it "is aliased to #cancel_instance" do
      expect(client.method(:cancel_process_instance)).to eq(client.method(:cancel_instance))
    end
  end
end
