# frozen_string_literal: true

require "spec_helper"
require "busybee/client"
require "busybee/credentials/insecure"

RSpec.describe Busybee::Client do
  describe ".new" do
    around do |example|
      original_cluster_address = Busybee.cluster_address
      original_credential_type = Busybee.credential_type
      Busybee.credential_type = nil
      example.run
      Busybee.cluster_address = original_cluster_address
      Busybee.credential_type = original_credential_type
    end

    context "with no arguments" do
      it "builds credentials using Credentials.build" do
        client = described_class.new
        expect(client.credentials).to be_a(Busybee::Credentials::Insecure)
      end

      it "uses Busybee.cluster_address via credentials" do
        Busybee.cluster_address = "configured:26500"
        client = described_class.new
        expect(client.cluster_address).to eq("configured:26500")
      end
    end

    context "with explicit credentials object" do
      let(:creds) { Busybee::Credentials::Insecure.new(cluster_address: "creds:26500") }

      it "uses provided credentials" do
        client = described_class.new(creds)
        expect(client.credentials).to be(creds)
      end

      it "delegates cluster_address to credentials" do
        client = described_class.new(creds)
        expect(client.cluster_address).to eq("creds:26500")
      end

      it "raises ArgumentError if credential kwargs are also provided" do
        expect { described_class.new(creds, insecure: true) }.to raise_error(ArgumentError, /cannot pass both/)
      end
    end

    context "with credential parameters" do
      it "passes parameters to Credentials.build" do
        client = described_class.new(insecure: true)
        expect(client.credentials).to be_a(Busybee::Credentials::Insecure)
      end

      it "passes cluster_address to Credentials.build" do
        client = described_class.new(insecure: true, cluster_address: "param:26500")
        expect(client.cluster_address).to eq("param:26500")
      end

      it "uses Busybee.cluster_address when cluster_address not provided" do
        Busybee.cluster_address = "default:26500"
        client = described_class.new(insecure: true)
        expect(client.cluster_address).to eq("default:26500")
      end
    end
  end

  describe "#cluster_address" do
    it "delegates to credentials.cluster_address" do
      creds = Busybee::Credentials::Insecure.new(cluster_address: "test:26500")
      client = described_class.new(creds)

      expect(client.cluster_address).to eq("test:26500")
      expect(client.cluster_address).to eq(creds.cluster_address)
    end
  end
end
