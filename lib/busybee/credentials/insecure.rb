# frozen_string_literal: true

require_relative "../credentials"

module Busybee
  class Credentials
    # Insecure credentials for local development, docker-compose, and CI.
    # No TLS, no authentication.
    #
    # @example Connect to local Zeebe
    #   credentials = Busybee::Credentials::Insecure.new
    #   stub = credentials.grpc_stub
    #
    # @example Connect to custom address
    #   credentials = Busybee::Credentials::Insecure.new(cluster_address: "zeebe:26500")
    #   stub = credentials.grpc_stub
    #
    class Insecure < Credentials
      def grpc_channel_credentials
        :this_channel_is_insecure
      end
    end
  end
end
