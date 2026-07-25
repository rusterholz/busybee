# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Credentials do
  describe ".build" do
    # As new credential types are added (OAuth, CamundaCloud, etc.),
    # add tests here to verify .build returns the correct type based on provided config.

    it "returns Insecure credentials when insecure: true" do
      creds = described_class.build(insecure: true)
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    end

    it "defaults to Insecure credentials when no config provided and no env vars set" do
      stub_credential_env_vars

      creds = described_class.build
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    end

    it "extracts credentials from environment variables when no params given" do
      stub_credential_env_vars
      allow(ENV).to receive(:fetch).with("CLUSTER_ADDRESS", nil).and_return("env:26500")

      creds = described_class.build
      expect(creds.cluster_address).to eq("env:26500")
    end

    it "allows explicit cluster_address kwarg to override env var" do
      stub_credential_env_vars
      allow(ENV).to receive(:fetch).with("CLUSTER_ADDRESS", nil).and_return("env:26500")

      creds = described_class.build(cluster_address: "override:26500")
      expect(creds.cluster_address).to eq("override:26500")
    end

    it "prefers explicit insecure: true over other credentials when credential_type is :insecure" do
      original = Busybee.credential_type
      Busybee.credential_type = :insecure

      creds = described_class.build(
        insecure: true,
        client_id: "test-client",
        client_secret: "test-secret",
        cluster_id: "test-cluster"
      )
      expect(creds).to be_a(Busybee::Credentials::Insecure)
    ensure
      Busybee.credential_type = original
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

    context "with incomplete or unrecognized params (no credential_type set)" do
      before do
        stub_credential_env_vars
        # Ensure no credential_type is set so autodetection runs
        allow(Busybee).to receive(:credential_type).and_return(nil)
      end

      it "raises CannotDetectCredentials when client_id is provided without other required params" do
        expect { described_class.build(client_id: "orphan-client") }.
          to raise_error(Busybee::CannotDetectCredentials, /Cannot detect credential type/)
      end

      it "raises CannotDetectCredentials when partial OAuth params are provided" do
        expect { described_class.build(client_id: "test", client_secret: "secret") }.
          to raise_error(Busybee::CannotDetectCredentials, /Cannot detect credential type/)
      end

      it "raises CannotDetectCredentials when partial CamundaCloud params are provided" do
        expect { described_class.build(client_id: "test", client_secret: "secret", cluster_id: "abc") }.
          to raise_error(Busybee::CannotDetectCredentials, /Cannot detect credential type/)
      end

      it "includes the unrecognized param keys in the error message" do
        expect { described_class.build(client_id: "test", some_unknown: "value") }.
          to raise_error(Busybee::CannotDetectCredentials, /client_id, some_unknown/)
      end

      it "suggests setting credential_type explicitly" do
        expect { described_class.build(client_id: "test") }.
          to raise_error(Busybee::CannotDetectCredentials, /Set Busybee\.credential_type explicitly/)
      end

      it "does NOT raise when params are empty (falls back to insecure)" do
        creds = described_class.build
        expect(creds).to be_a(Busybee::Credentials::Insecure)
      end

      it "does NOT raise when only insecure: true is provided" do
        creds = described_class.build(insecure: true)
        expect(creds).to be_a(Busybee::Credentials::Insecure)
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
        original = Busybee.credential_type
        Busybee.credential_type = :oauth

        creds = described_class.build(
          token_url: "https://auth.example.com/token",
          client_id: "test",
          client_secret: "secret",
          audience: "api",
          cluster_address: "oauth.zeebe.io:443"
        )
        expect(creds.cluster_address).to eq("oauth.zeebe.io:443")
      ensure
        Busybee.credential_type = original
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
    it "creates a Gateway stub with cluster_address, channel credentials, and keepalive channel args" do
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      stub_double = instance_double(Busybee::GRPC::Gateway::Stub)
      expect(Busybee::GRPC::Gateway::Stub).to receive(:new). # rubocop:disable RSpec/StubbedMock, RSpec/MessageSpies
        with("test:26500", :this_channel_is_insecure, channel_args: hash_including(
          "grpc.keepalive_time_ms" => 45_000,
          "grpc.keepalive_timeout_ms" => 20_000,
          "grpc.keepalive_permit_without_calls" => 1,
          "grpc.http2.max_pings_without_data" => 0
        )).
        and_return(stub_double)

      expect(creds.grpc_stub).to eq(stub_double)
    end

    it "converts an ActiveSupport::Duration keepalive interval to wire milliseconds" do
      described_class.new # ensure lib loaded
      allow(Busybee).to receive_messages(grpc_keepalive_interval: 30.seconds, grpc_keepalive_timeout: 5.seconds)
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      expect(Busybee::GRPC::Gateway::Stub).to receive(:new). # rubocop:disable RSpec/StubbedMock, RSpec/MessageSpies
        with("test:26500", :this_channel_is_insecure, channel_args: hash_including(
          "grpc.keepalive_time_ms" => 30_000, "grpc.keepalive_timeout_ms" => 5_000
        )).
        and_return(instance_double(Busybee::GRPC::Gateway::Stub))

      creds.grpc_stub
    end

    it "omits all keepalive args when both knobs are false" do
      allow(Busybee).to receive_messages(grpc_keepalive_interval: false, grpc_keepalive_timeout: false)
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      expect(Busybee::GRPC::Gateway::Stub).to receive(:new) do |_addr, _creds, channel_args:| # rubocop:disable RSpec/MessageSpies
        expect(channel_args.keys).to all(satisfy { |k| !k.start_with?("grpc.keepalive", "grpc.http2.max_pings") })
        instance_double(Busybee::GRPC::Gateway::Stub)
      end

      creds.grpc_stub
    end

    it "raises when only one keepalive knob is disabled" do
      allow(Busybee).to receive_messages(grpc_keepalive_interval: false, grpc_keepalive_timeout: 20_000)
      creds = described_class.new(cluster_address: "test:26500")
      allow(creds).to receive(:grpc_channel_credentials).and_return(:this_channel_is_insecure)

      expect { creds.grpc_stub }.to raise_error(ArgumentError, /both.*set.*both.*false/i)
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
