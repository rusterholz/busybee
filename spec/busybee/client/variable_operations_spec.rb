# frozen_string_literal: true

RSpec.describe Busybee::Client::VariableOperations do
  let(:client) { Busybee::Client.new(insecure: true, cluster_address: "localhost:26500") }
  let(:stub) { instance_double(Busybee::GRPC::Gateway::Stub) }

  before { allow(client.credentials).to receive(:grpc_stub).and_return(stub) }

  describe "#set_variables" do
    it "sets variables on an element instance" do
      response = double(key: 12345)
      allow(stub).to receive(:set_variables).and_return(response)

      result = client.set_variables(67890, vars: { orderId: 123, status: "active" })

      expect(result).to eq(12345)
      expect(stub).to have_received(:set_variables).with(
        having_attributes(
          elementInstanceKey: 67890,
          variables: JSON.generate({ orderId: 123, status: "active" }),
          local: false
        )
      )
    end

    it "supports local scope" do
      response = double(key: 12345)
      allow(stub).to receive(:set_variables).and_return(response)

      client.set_variables(67890, vars: { tempVar: "value" }, local: true)

      expect(stub).to have_received(:set_variables).with(
        having_attributes(local: true)
      )
    end

    it "defaults to empty vars hash" do
      response = double(key: 12345)
      allow(stub).to receive(:set_variables).and_return(response)

      client.set_variables(67890)

      expect(stub).to have_received(:set_variables).with(
        having_attributes(
          variables: JSON.generate({})
        )
      )
    end

    it "converts element_instance_key to integer" do
      response = double(key: 12345)
      allow(stub).to receive(:set_variables).and_return(response)

      client.set_variables("67890", vars: {})

      expect(stub).to have_received(:set_variables).with(
        having_attributes(elementInstanceKey: 67890)
      )
    end

    it "raises ArgumentError if vars is not a Hash" do
      expect { client.set_variables(67890, vars: "not a hash") }.to raise_error(ArgumentError, "vars must be a Hash")
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:set_variables).and_raise(GRPC::NotFound.new("element not found"))

      expect { client.set_variables(67890, vars: {}) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
        expect(error.grpc_status).to eq(:not_found)
      end
    end
  end

  describe "#resolve_incident" do
    it "resolves an incident" do
      response = double
      allow(stub).to receive(:resolve_incident).and_return(response)

      result = client.resolve_incident(54321)

      expect(result).to be true
      expect(stub).to have_received(:resolve_incident).with(
        having_attributes(incidentKey: 54321)
      )
    end

    it "converts incident_key to integer" do
      response = double
      allow(stub).to receive(:resolve_incident).and_return(response)

      client.resolve_incident("54321")

      expect(stub).to have_received(:resolve_incident).with(
        having_attributes(incidentKey: 54321)
      )
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      allow(stub).to receive(:resolve_incident).and_raise(GRPC::NotFound.new("incident not found"))

      expect { client.resolve_incident(54321) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
        expect(error.grpc_status).to eq(:not_found)
      end
    end
  end
end
