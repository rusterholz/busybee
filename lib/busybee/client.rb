# frozen_string_literal: true

require "busybee/credentials"
require "busybee/client/error_handling"
require "busybee/client/message_operations"
require "busybee/client/process_operations"
require "busybee/client/variable_operations"

module Busybee
  # Ruby-idiomatic wrapper around Zeebe GRPC API.
  #
  # @example Basic usage with local Zeebe
  #   client = Busybee::Client.new(insecure: true)
  #   client.deploy_process("workflow.bpmn")
  #
  # @example With explicit credentials
  #   credentials = Busybee::Credentials::Insecure.new
  #   client = Busybee::Client.new(credentials)
  #
  # @example With gem-level configuration
  #   Busybee.credential_type = :insecure
  #   client = Busybee::Client.new
  #
  class Client
    include ErrorHandling
    include MessageOperations
    include ProcessOperations
    include VariableOperations

    attr_reader :credentials

    # Create a new client.
    #
    # @param credentials [Credentials, nil] Explicit credentials object (first positional arg)
    # @param params [Hash, nil] Credential kwargs (passed to Credentials.build if no explicit credentials)
    # @raise [ArgumentError] if both credentials object and credential params are provided
    #
    # @example With credential parameters:
    #   Client.new(insecure: true, cluster_address: "localhost:26500")
    #
    # @example With explicit credentials:
    #   creds = Credentials::Insecure.new(cluster_address: "localhost:26500")
    #   Client.new(creds)
    #
    # @example Inferred entirely from gem configuration or env vars:
    #   Client.new
    #
    def initialize(credentials = nil, **params)
      if credentials && params.any?
        raise ArgumentError, "cannot pass both explicit credentials and credential parameters"
      end

      @credentials = if credentials
                       credentials
                     elsif params.empty? && Busybee.credentials.is_a?(Busybee::Credentials)
                       Busybee.credentials
                     else
                       Credentials.build(**params) # will attempt to autodetect from env if no params are given
                     end
    end

    # Returns the cluster address from credentials.
    # @return [String] Cluster address (host:port)
    def cluster_address
      credentials.cluster_address
    end

    private

    # Returns the GRPC stub for making API calls.
    # @return [Busybee::GRPC::Gateway::Stub]
    def stub
      credentials.grpc_stub
    end
  end
end
