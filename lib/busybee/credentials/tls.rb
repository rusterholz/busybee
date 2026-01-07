# frozen_string_literal: true

require "grpc"
require_relative "../credentials"

module Busybee
  class Credentials
    # TLS credentials with server certificate verification.
    # No client authentication (mTLS not supported in v0.2).
    #
    # @example With system default certificates
    #   credentials = Busybee::Credentials::TLS.new(cluster_address: "zeebe.example.com:443")
    #   stub = credentials.grpc_stub
    #
    # @example With custom CA certificate
    #   credentials = Busybee::Credentials::TLS.new(
    #     cluster_address: "zeebe.example.com:443",
    #     certificate_file: "/path/to/ca-cert.pem"
    #   )
    #   stub = credentials.grpc_stub
    #
    class TLS < Credentials
      attr_reader :certificate_file

      # @param cluster_address [String, nil] Zeebe cluster address (host:port)
      # @param certificate_file [String, nil] Path to CA certificate file.
      #   If nil, uses system default certificates.
      def initialize(cluster_address: nil, certificate_file: nil)
        super(cluster_address: cluster_address)
        @certificate_file = certificate_file
      end

      def grpc_channel_credentials
        if certificate_file
          ::GRPC::Core::ChannelCredentials.new(File.read(certificate_file))
        else
          ::GRPC::Core::ChannelCredentials.new
        end
      end
    end
  end
end
