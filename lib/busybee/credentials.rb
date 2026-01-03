# frozen_string_literal: true

module Busybee
  # Base class for credentials. Defines interface for all credential types.
  # Subclasses must implement #channel_credentials.
  class Credentials
    # Returns gRPC channel credentials for Stub.new
    # @return [Symbol, GRPC::Core::ChannelCredentials]
    def channel_credentials
      raise NotImplementedError, "#{self.class} must implement #channel_credentials"
    end
  end
end
