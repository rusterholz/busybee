# frozen_string_literal: true

require "spec_helper"
require "busybee/credentials/insecure"

RSpec.describe Busybee::Credentials::Insecure do
  describe "#grpc_channel_credentials" do
    it "returns :this_channel_is_insecure" do
      expect(described_class.new.grpc_channel_credentials).to eq(:this_channel_is_insecure)
    end
  end

  describe "#grpc_stub" do
    it "returns a GRPC Gateway stub" do
      creds = described_class.new
      expect(creds.grpc_stub).to be_a(Busybee::GRPC::Gateway::Stub)
    end

    it "uses custom cluster_address if provided" do
      creds = described_class.new(cluster_address: "custom:26500")
      expect(creds.cluster_address).to eq("custom:26500")
    end
  end

  it "is a subclass of Credentials" do
    expect(described_class.superclass).to eq(Busybee::Credentials)
  end
end
