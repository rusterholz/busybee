# frozen_string_literal: true

require "busybee"

module Busybee
  # Base class for credentials. Defines interface for all credential types.
  #
  # Credentials objects are responsible for:
  # - Knowing which cluster address to connect to
  # - Providing gRPC channel credentials for authentication
  # - Creating and memoizing gRPC stub instances
  #
  # Subclasses must implement #grpc_channel_credentials.
  #
  # @example Direct stub access
  #   credentials = Busybee::Credentials::Insecure.new
  #   stub = credentials.grpc_stub
  #   response = stub.topology(Busybee::GRPC::TopologyRequest.new)
  #
  class Credentials
    attr_reader :cluster_address

    class << self
      # Factory method to build appropriate credentials based on configuration.
      #
      # First checks Busybee.credential_type for explicit type selection.
      # If not set, autodetects credential type based on which keys are present in params.
      # If no keys are given in params, attempts to load them from environment vars.
      #
      # @param cluster_address [String, nil] Override cluster address
      # @param params [Hash] Configuration parameters (keys inform credential type selection)
      # @option params [Boolean] :insecure Use insecure connection (no TLS, no auth)
      # @return [Credentials] Appropriate credentials instance
      #
      # @example Insecure for local development
      #   Credentials.build(insecure: true)
      #
      # @example With explicit type configuration
      #   Busybee.credential_type = :insecure
      #   Credentials.build  # Uses configured type
      #
      def build(cluster_address: nil, **params)
        if params.empty?
          params = extract_possible_credential_params_from_env
          extracted_address = params.delete(:cluster_address) # always delete to avoid duplicate keyword arg
          cluster_address ||= extracted_address # allow explicit kwarg to override env
        end

        case Busybee.credential_type
        when :insecure
          build_insecure(cluster_address: cluster_address, **params)
        when :tls
          build_tls(cluster_address: cluster_address, **params)
        when :oauth
          build_oauth(cluster_address: cluster_address, **params)
        when :camunda_cloud
          build_camunda_cloud(cluster_address: cluster_address, **params)
        else
          autodetect_credentials(cluster_address: cluster_address, **params)
        end
      end

      private

      # Autodetects credential type based on provided parameters.
      # As new credential types are added, extend this method with detection logic.
      def autodetect_credentials(cluster_address: nil, **params)
        if tls_keys?(params)
          build_tls(cluster_address: cluster_address, **params)
        elsif oauth_keys?(params)
          build_oauth(cluster_address: cluster_address, **params)
        elsif camunda_cloud_keys?(params)
          build_camunda_cloud(cluster_address: cluster_address, **params)
        else
          # Default to insecure for local development (includes explicit insecure: true)
          build_insecure(cluster_address: cluster_address, **params)
        end
      end

      def id_and_secret?(params)
        params[:client_id] && params[:client_secret]
      end

      def tls_keys?(params)
        !id_and_secret?(params) && (params[:certificate_file] || params[:tls])
      end

      def oauth_keys?(params)
        id_and_secret?(params) && params[:token_url] && params[:audience]
      end

      def camunda_cloud_keys?(params)
        id_and_secret?(params) && params[:cluster_id] && params[:region]
      end

      def build_insecure(cluster_address: nil, **_)
        require "busybee/credentials/insecure"
        Insecure.new(cluster_address: cluster_address)
      end

      def build_tls(cluster_address: nil, certificate_file: nil, **_)
        require "busybee/credentials/tls"
        TLS.new(cluster_address: cluster_address, certificate_file: certificate_file)
      end

      def build_oauth( # rubocop:disable Metrics/ParameterLists
        cluster_address: nil,
        token_url: nil,
        client_id: nil,
        client_secret: nil,
        audience: nil,
        scope: nil,
        certificate_file: nil,
        **_
      )
        require "busybee/credentials/oauth"
        OAuth.new(
          cluster_address: cluster_address,
          token_url: token_url,
          client_id: client_id,
          client_secret: client_secret,
          audience: audience,
          scope: scope,
          certificate_file: certificate_file
        )
      end

      # NOTE: cluster_address is intentionally omitted - CamundaCloud constructs it from cluster_id and region
      def build_camunda_cloud(client_id: nil, client_secret: nil, cluster_id: nil, region: nil, scope: nil, **_) # rubocop:disable Metrics/ParameterLists
        require "busybee/credentials/camunda_cloud"
        CamundaCloud.new(
          client_id: client_id,
          client_secret: client_secret,
          cluster_id: cluster_id,
          region: region,
          scope: scope
        )
      end

      # Attempt to extract credentials from environment variables, if present.
      def extract_possible_credential_params_from_env
        {
          cluster_address: ENV.fetch("CLUSTER_ADDRESS", nil),
          # Camunda Cloud params
          client_id: ENV.fetch("CAMUNDA_CLIENT_ID", nil),
          client_secret: ENV.fetch("CAMUNDA_CLIENT_SECRET", nil),
          cluster_id: ENV.fetch("CAMUNDA_CLUSTER_ID", nil),
          region: ENV.fetch("CAMUNDA_CLUSTER_REGION", nil),
          # OAuth params
          token_url: ENV.fetch("ZEEBE_TOKEN_URL", nil),
          audience: ENV.fetch("ZEEBE_AUDIENCE", nil),
          scope: ENV.fetch("ZEEBE_SCOPE", nil),
          # TLS params
          certificate_file: ENV.fetch("ZEEBE_CERTIFICATE_FILE", nil)
        }.compact
      end
    end

    # @param cluster_address [String, nil] Zeebe cluster address (host:port)
    #   If nil, falls back to Busybee.cluster_address
    def initialize(cluster_address: nil)
      @cluster_address = cluster_address || Busybee.cluster_address
    end

    # Returns a ready-to-use gRPC stub for the Zeebe Gateway API.
    # The stub is memoized internally - callers should not cache it themselves.
    # For credentials that handle token refresh (like OAuth), this ensures
    # the stub can be replaced transparently when tokens are refreshed.
    #
    # @return [Busybee::GRPC::Gateway::Stub]
    def grpc_stub
      @grpc_stub ||= begin
        require "busybee/grpc"
        Busybee::GRPC::Gateway::Stub.new(cluster_address, grpc_channel_credentials)
      end
    end

    # Returns gRPC channel credentials for authentication.
    # Subclasses must implement this method.
    #
    # @return [Symbol, GRPC::Core::ChannelCredentials]
    #   - :this_channel_is_insecure for insecure connections
    #   - GRPC::Core::ChannelCredentials for TLS/OAuth
    def grpc_channel_credentials
      raise NotImplementedError, "#{self.class} must implement #grpc_channel_credentials"
    end
  end
end
