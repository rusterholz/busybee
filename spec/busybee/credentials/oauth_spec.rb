# frozen_string_literal: true

require "spec_helper"
require "busybee/credentials/oauth"
require "active_support/testing/time_helpers"

RSpec.describe Busybee::Credentials::OAuth do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::TimeHelpers

  subject do
    described_class.new(
      token_url: token_url,
      client_id: "test-client",
      client_secret: "test-secret",
      audience: "zeebe-api",
      cluster_address: "oauth.zeebe.io:443"
    )
  end

  let(:token_url) { "https://auth.example.com/oauth/token" }
  let(:access_token) { "test-token-12345" }
  let(:token_response) do
    {
      access_token: access_token,
      expires_in: 3600,
      token_type: "Bearer"
    }
  end

  before do
    stub_request(:post, token_url)
      .with(
        body: {
          "grant_type" => "client_credentials",
          "client_id" => "test-client",
          "client_secret" => "test-secret",
          "audience" => "zeebe-api"
        }
      )
      .to_return(
        status: 200,
        body: token_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#grpc_channel_credentials" do
    it "returns composite GRPC credentials (TLS + OAuth)" do
      result = subject.grpc_channel_credentials
      expect(result).to be_a(GRPC::Core::ChannelCredentials)
    end

    it "fetches OAuth token when token_updater callback is invoked" do
      result = subject.send(:token_updater, nil)
      expect(result).to eq({ authorization: "Bearer #{access_token}" })
      expect(WebMock).to have_requested(:post, token_url).once
    end

    it "caches token and doesn't refetch on subsequent calls" do
      subject.send(:token_updater, nil)
      subject.send(:token_updater, nil)
      subject.send(:token_updater, nil)

      # Should only fetch once, then cache
      expect(WebMock).to have_requested(:post, token_url).once
    end
  end

  describe "token refresh behavior" do
    it "refreshes token when expired" do
      # First call fetches token
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).once

      # Simulate token expiration by advancing time past expiry
      # Token expires at Time.now + 3600, but refreshes 30s early
      travel 3600 - 29

      # Second call should trigger refresh
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).twice
    end

    it "refreshes token 30 seconds before expiry" do
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).once

      # Advance time to exactly 30s before expiry
      travel 3600 - 30

      # Should trigger refresh at this point
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).twice
    end

    it "does not refresh if token still valid" do
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).once

      # Advance time but not enough to trigger refresh (still >30s until expiry)
      travel 100

      subject.send(:token_updater, nil)
      # Should still only have one request
      expect(WebMock).to have_requested(:post, token_url).once
    end

    it "uses expires_in from token response" do
      stub_request(:post, token_url)
        .to_return(
          status: 200,
          body: { access_token: "short-token", expires_in: 60 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      subject.send(:token_updater, nil)

      # Token expires in 60s, refresh at 30s, so should be valid for 29s
      travel 29
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).once

      # But should refresh at 30s
      travel 1 # Total: 30s
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).twice
    end

    it "defaults to 3600s expiry if expires_in not in response" do
      stub_request(:post, token_url)
        .to_return(
          status: 200,
          body: { access_token: "no-expiry-token" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      subject.send(:token_updater, nil)

      # Should use default 3600s expiry
      travel 3600 - 31
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).once

      travel 1 # Total: 3600 - 30
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, token_url).twice
    end
  end

  describe "certificate file support" do
    let(:cert_contents) { "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----" }
    let(:cert_file) do
      Tempfile.new(["cert", ".pem"]).tap do |f|
        f.write(cert_contents)
        f.close
      end
    end

    after { cert_file.unlink }

    it "accepts certificate_file parameter" do
      creds = described_class.new(
        token_url: token_url,
        client_id: "test",
        client_secret: "secret",
        audience: "api",
        certificate_file: cert_file.path
      )

      # Should not raise error
      expect { creds.grpc_channel_credentials }.not_to raise_error
    end

    it "reads certificate file when provided" do
      creds = described_class.new(
        token_url: token_url,
        client_id: "test",
        client_secret: "secret",
        audience: "api",
        certificate_file: cert_file.path
      )

      allow(File).to receive(:read).with(cert_file.path).and_return(cert_contents)
      allow(GRPC::Core::ChannelCredentials).to receive(:new).and_call_original
      allow(GRPC::Core::CallCredentials).to receive(:new).and_call_original

      creds.grpc_channel_credentials

      expect(File).to have_received(:read).with(cert_file.path)
      expect(GRPC::Core::ChannelCredentials).to have_received(:new).with(cert_contents)
    end

    it "uses system defaults when certificate_file not provided" do
      allow(GRPC::Core::ChannelCredentials).to receive(:new).and_call_original
      allow(GRPC::Core::CallCredentials).to receive(:new).and_call_original

      subject.grpc_channel_credentials

      expect(GRPC::Core::ChannelCredentials).to have_received(:new).with(no_args)
    end
  end

  describe "error handling" do
    it "raises Busybee::OAuthTokenRefreshFailed when token fetch fails with 401" do
      stub_request(:post, token_url)
        .to_return(status: 401, body: "Unauthorized")

      expect { subject.send(:token_updater, nil) }
        .to raise_error(Busybee::OAuthTokenRefreshFailed, /HTTP 401/)
    end

    it "raises Busybee::OAuthTokenRefreshFailed when token fetch fails with 500" do
      stub_request(:post, token_url)
        .to_return(status: 500, body: "Internal Server Error")

      expect { subject.send(:token_updater, nil) }
        .to raise_error(Busybee::OAuthTokenRefreshFailed, /HTTP 500/)
    end

    it "raises Busybee::OAuthInvalidResponse when token response is invalid JSON" do
      stub_request(:post, token_url)
        .to_return(status: 200, body: "not json")

      expect { subject.send(:token_updater, nil) }
        .to raise_error(Busybee::OAuthInvalidResponse, /Invalid JSON/)
    end
  end

  describe "#cluster_address" do
    it "accepts and stores cluster_address parameter" do
      expect(subject.cluster_address).to eq("oauth.zeebe.io:443")
    end
  end

  it "is a subclass of Credentials" do
    expect(described_class.superclass).to eq(Busybee::Credentials)
  end
end
