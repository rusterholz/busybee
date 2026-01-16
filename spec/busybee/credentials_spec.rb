# frozen_string_literal: true

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

    context "with TLS credentials" do
      it "returns TLS credentials when tls: true" do
        creds = described_class.build(tls: true)
        expect(creds).to be_a(Busybee::Credentials::TLS)
      end

      it "returns TLS credentials when credential_type is :tls" do
        original = Busybee.credential_type
        Busybee.credential_type = :tls

        creds = described_class.build
        expect(creds).to be_a(Busybee::Credentials::TLS)
      ensure
        Busybee.credential_type = original
      end

      it "passes certificate_file parameter to TLS credentials" do
        creds = described_class.build(tls: true, certificate_file: "/path/to/cert.pem")
        expect(creds.certificate_file).to eq("/path/to/cert.pem")
      end

      it "passes cluster_address to TLS credentials" do
        creds = described_class.build(tls: true, cluster_address: "secure.zeebe.io:443")
        expect(creds.cluster_address).to eq("secure.zeebe.io:443")
      end
    end

    context "with OAuth credentials" do
      it "returns OAuth credentials when credential_type is :oauth" do
        original = Busybee.credential_type
        Busybee.credential_type = :oauth

        creds = described_class.build(
          token_url: "https://auth.example.com/token",
          client_id: "test-client",
          client_secret: "test-secret",
          audience: "test-audience"
        )
        expect(creds).to be_a(Busybee::Credentials::OAuth)
      ensure
        Busybee.credential_type = original
      end

      it "auto-detects OAuth when OAuth-specific params are present" do
        creds = described_class.build(
          token_url: "https://auth.example.com/token",
          client_id: "test-client",
          client_secret: "test-secret",
          audience: "test-audience"
        )
        expect(creds).to be_a(Busybee::Credentials::OAuth)
      end

      it "passes OAuth parameters through to OAuth credentials" do
        creds = described_class.build(
          credential_type: :oauth,
          token_url: "https://auth.example.com/token",
          client_id: "test-client",
          client_secret: "test-secret",
          audience: "test-audience"
        )

        request = creds.send(:build_token_request)
        body = URI.decode_www_form(request.body).to_h

        expect(body["client_id"]).to eq("test-client")
        expect(body["client_secret"]).to eq("test-secret")
        expect(body["audience"]).to eq("test-audience")
      end

      it "passes scope through to OAuth credentials when provided" do
        creds = described_class.build(
          credential_type: :oauth,
          token_url: "https://auth.example.com/token",
          client_id: "test-client",
          client_secret: "test-secret",
          audience: "test-audience",
          scope: "Zeebe Tasklist"
        )

        request = creds.send(:build_token_request)
        body = URI.decode_www_form(request.body).to_h

        expect(body["scope"]).to eq("Zeebe Tasklist")
      end

      it "passes cluster_address to OAuth credentials" do
        creds = described_class.build(
          credential_type: :oauth,
          cluster_address: "oauth.zeebe.io:443"
        )
        expect(creds.cluster_address).to eq("oauth.zeebe.io:443")
      end
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
      expect { described_class.new.grpc_channel_credentials }.
        to raise_error(NotImplementedError, /must implement/)
    end
  end

  describe "#grpc_stub" do
    it "creates a Gateway stub with cluster_address and channel credentials" do
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      stub_double = instance_double(Busybee::GRPC::Gateway::Stub)
      expect(Busybee::GRPC::Gateway::Stub).to receive(:new). # rubocop:disable RSpec/StubbedMock, RSpec/MessageSpies
        with("test:26500", :this_channel_is_insecure).
        and_return(stub_double)

      expect(creds.grpc_stub).to eq(stub_double)
    end

    it "memoizes the stub instance" do
      creds = described_class.new
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      stub_double = instance_double(Busybee::GRPC::Gateway::Stub)
      expect(Busybee::GRPC::Gateway::Stub).to receive(:new).once.and_return(stub_double) # rubocop:disable RSpec/MessageSpies

      # Call twice - Stub.new should only be called once due to memoization
      creds.grpc_stub
      creds.grpc_stub
    end

    it "raises NotImplementedError when grpc_channel_credentials not implemented" do
      expect { described_class.new.grpc_stub }.
        to raise_error(NotImplementedError, /must implement/)
    end
  end
end
