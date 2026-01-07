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
        case Busybee.credential_type
        when :insecure
          build_insecure(cluster_address: cluster_address)
        when :tls
          build_tls(cluster_address: cluster_address, certificate_file: params[:certificate_file])
        # As new credential types are added, add cases here (e.g., :oauth, :camunda_cloud)
        else
          autodetect_credentials(cluster_address: cluster_address, **params)
        end
      end

      private

      # Autodetects credential type based on provided parameters.
      # As new credential types are added, extend this method with detection logic.
      def autodetect_credentials(cluster_address: nil, **params)
        return build_insecure(cluster_address: cluster_address) if params[:insecure]
        return build_tls(cluster_address: cluster_address, certificate_file: params[:certificate_file]) if params[:tls]

        # As new credential types are added, add autodetection logic here.
        # Example: if params[:client_id] && params[:client_secret] && params[:cluster_id]
        #   return build_camunda_cloud(...)

        # Default to insecure for local development
        build_insecure(cluster_address: cluster_address)
      end

      def build_insecure(cluster_address: nil)
        require_relative "credentials/insecure"
        Insecure.new(cluster_address: cluster_address)
      end

      def build_tls(cluster_address: nil, certificate_file: nil)
        require_relative "credentials/tls"
        TLS.new(cluster_address: cluster_address, certificate_file: certificate_file)
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
