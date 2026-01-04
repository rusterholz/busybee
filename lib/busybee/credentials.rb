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
