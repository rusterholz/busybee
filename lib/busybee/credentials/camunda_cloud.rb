# frozen_string_literal: true

require "busybee/credentials/oauth"

module Busybee
  class Credentials
    # Camunda Cloud-specific OAuth credentials.
    # Automatically derives the cluster address and OAuth configuration
    # from cluster ID and region.
    #
    # @example Basic usage
    #   credentials = Busybee::Credentials::CamundaCloud.new(
    #     client_id: ENV["CAMUNDA_CLIENT_ID"],
    #     client_secret: ENV["CAMUNDA_CLIENT_SECRET"],
    #     cluster_id: ENV["CAMUNDA_CLUSTER_ID"],
    #     region: ENV["CAMUNDA_CLUSTER_REGION"]
    #   )
    #   stub = credentials.grpc_stub
    #
    # @example With scope for API access control
    #   credentials = Busybee::Credentials::CamundaCloud.new(
    #     client_id: ENV["CAMUNDA_CLIENT_ID"],
    #     client_secret: ENV["CAMUNDA_CLIENT_SECRET"],
    #     cluster_id: ENV["CAMUNDA_CLUSTER_ID"],
    #     region: ENV["CAMUNDA_CLUSTER_REGION"],
    #     scope: "Zeebe Tasklist Operate"
    #   )
    #
    class CamundaCloud < OAuth
      CAMUNDA_AUTH_URL = "https://login.cloud.camunda.io/oauth/token"
      CAMUNDA_AUDIENCE = "zeebe.camunda.io"

      # @param client_id [String] Camunda Cloud client ID
      # @param client_secret [String] Camunda Cloud client secret
      # @param cluster_id [String] Camunda Cloud cluster ID
      # @param region [String] Camunda Cloud region (e.g., "bru-2", "us-east-1")
      # @param scope [String, nil] Optional OAuth2 scope for API access control
      def initialize(client_id:, client_secret:, cluster_id:, region:, scope: nil)
        @cluster_id = cluster_id
        @region = region

        super(
          token_url: CAMUNDA_AUTH_URL,
          client_id: client_id,
          client_secret: client_secret,
          audience: CAMUNDA_AUDIENCE,
          scope: scope,
          cluster_address: "#{cluster_id}.#{region}.zeebe.camunda.io:443"
        )
      end
    end
  end
end
