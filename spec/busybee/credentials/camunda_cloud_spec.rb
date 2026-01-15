# frozen_string_literal: true

require "busybee/credentials/camunda_cloud"

RSpec.describe Busybee::Credentials::CamundaCloud do
  subject do
    described_class.new(
      client_id: "test-client",
      client_secret: "test-secret",
      cluster_id: "abc-123-def",
      region: "bru-2"
    )
  end

  let(:expected_token_url) { "https://login.cloud.camunda.io/oauth/token" }
  let(:expected_audience) { "zeebe.camunda.io" }
  let(:access_token) { "camunda-cloud-token-12345" }
  let(:token_response) do
    {
      access_token: access_token,
      expires_in: 3600,
      token_type: "Bearer"
    }
  end

  before do
    stub_request(:post, expected_token_url)
      .with(
        body: {
          "grant_type" => "client_credentials",
          "client_id" => "test-client",
          "client_secret" => "test-secret",
          "audience" => expected_audience
        }
      )
      .to_return(
        status: 200,
        body: token_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#cluster_address" do
    it "builds Camunda Cloud address from cluster_id and region" do
      expect(subject.cluster_address).to eq("abc-123-def.bru-2.zeebe.camunda.io:443")
    end
  end

  describe "OAuth configuration" do
    it "uses Camunda Cloud auth endpoint" do
      # Trigger token fetch to verify endpoint is correct
      subject.send(:token_updater, nil)
      expect(WebMock).to have_requested(:post, expected_token_url).once
    end

    it "uses generic Camunda Cloud audience" do
      # Verify the audience in the token request
      subject.send(:token_updater, nil)

      expect(WebMock).to have_requested(:post, expected_token_url)
        .with(body: hash_including("audience" => "zeebe.camunda.io"))
        .once
    end

    it "passes through client_id and client_secret" do
      subject.send(:token_updater, nil)

      expect(WebMock).to have_requested(:post, expected_token_url)
        .with(body: hash_including(
          "client_id" => "test-client",
          "client_secret" => "test-secret"
        ))
        .once
    end
  end

  describe "scope support" do
    it "includes scope in token request when provided" do # rubocop:disable RSpec/ExampleLength
      creds = described_class.new(
        client_id: "test-client",
        client_secret: "test-secret",
        cluster_id: "abc-123-def",
        region: "bru-2",
        scope: "Zeebe Tasklist"
      )

      stub_request(:post, expected_token_url)
        .with(
          body: hash_including("scope" => "Zeebe Tasklist")
        )
        .to_return(
          status: 200,
          body: token_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      creds.send(:token_updater, nil)

      expect(WebMock).to have_requested(:post, expected_token_url)
        .with(body: hash_including("scope" => "Zeebe Tasklist"))
        .once
    end

    it "omits scope from token request when not provided" do
      request = subject.send(:build_token_request)
      body = URI.decode_www_form(request.body).to_h

      expect(body).not_to have_key("scope")
    end
  end

  describe "#grpc_channel_credentials" do
    it "returns composite credentials from OAuth parent" do
      result = subject.grpc_channel_credentials
      expect(result).to be_a(GRPC::Core::ChannelCredentials)
    end
  end

  it "is a subclass of OAuth" do
    expect(described_class.superclass).to eq(Busybee::Credentials::OAuth)
  end

  describe "with different regions" do
    it "builds correct address for us-east-1" do
      creds = described_class.new(
        client_id: "x",
        client_secret: "y",
        cluster_id: "my-cluster",
        region: "us-east-1"
      )
      expect(creds.cluster_address).to eq("my-cluster.us-east-1.zeebe.camunda.io:443")
    end
  end
end
