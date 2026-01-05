# frozen_string_literal: true

require "spec_helper"
require "busybee/credentials"

RSpec.describe Busybee::Credentials do
  describe ".build" do
    # As new credential types are added (OAuth, CamundaCloud, etc.),
    # add tests here to verify .build returns the correct type based on provided config.

    it "returns Insecure credentials when insecure: true" do
      creds = described_class.build(insecure: true)
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    end

    it "defaults to Insecure credentials when no config provided" do
      creds = described_class.build
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    end

    it "prefers explicit insecure: true over other credentials" do
      creds = described_class.build(
        insecure: true,
        client_id: "test-client",
        client_secret: "test-secret",
        cluster_id: "test-cluster"
      )
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    end

    it "passes cluster_address through to credentials" do
      creds = described_class.build(insecure: true, cluster_address: "custom:26500")
      expect(creds.cluster_address).to eq("custom:26500")
    end
  end

  describe "#cluster_address" do
    it "defaults to Busybee.cluster_address" do
      original = Busybee.cluster_address
      Busybee.cluster_address = "default:26500"

      creds = described_class.new
      expect(creds.cluster_address).to eq("default:26500")

      Busybee.cluster_address = original
    end

    it "can be overridden at initialization" do
      creds = described_class.new(cluster_address: "custom:26500")
      expect(creds.cluster_address).to eq("custom:26500")
    end
  end

  describe "#grpc_channel_credentials" do
    it "raises NotImplementedError" do
      expect { described_class.new.grpc_channel_credentials }
        .to raise_error(NotImplementedError, /must implement/)
    end
  end

  describe "#grpc_stub" do
    it "creates a Gateway stub with cluster_address and channel credentials" do
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      stub_double = instance_double(Busybee::GRPC::Gateway::Stub)
      expect(Busybee::GRPC::Gateway::Stub).to receive(:new) # rubocop:disable RSpec/StubbedMock
        .with("test:26500", :this_channel_is_insecure)
        .and_return(stub_double)

      expect(creds.grpc_stub).to eq(stub_double)
    end

    it "memoizes the stub instance" do
      creds = described_class.new
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      stub_double = instance_double(Busybee::GRPC::Gateway::Stub)
      expect(Busybee::GRPC::Gateway::Stub).to receive(:new).once.and_return(stub_double)

      # Call twice - Stub.new should only be called once due to memoization
      creds.grpc_stub
      creds.grpc_stub
    end

    it "raises NotImplementedError when grpc_channel_credentials not implemented" do
      expect { described_class.new.grpc_stub }
        .to raise_error(NotImplementedError, /must implement/)
    end
  end
end
