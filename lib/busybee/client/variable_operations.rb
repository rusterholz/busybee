# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  class Client
    # Variable and incident operations for managing process instance state.
    module VariableOperations
      # Set variables on a process instance or element instance.
      #
      # @param element_instance_key [Integer, String] The element instance key
      #   (process instance key or service task key)
      # @param vars [Hash] Variables to set
      # @param local [Boolean] If true, variables are set only in the local scope
      #   (not propagated to parent scopes)
      # @return [Integer] The variable set operation key
      # @raise [ArgumentError] if vars is not a Hash
      # @raise [Busybee::GRPC::Error] if setting variables fails
      #
      # @example Set variables on a process instance
      #   key = client.set_variables(process_instance_key, vars: { status: "approved" })
      #   # => 12345
      #
      # @example Set local variables on an element
      #   client.set_variables(element_key, vars: { tempData: "value" }, local: true)
      #
      def set_variables(element_instance_key, vars: {}, local: false)
        raise ArgumentError, "vars must be a Hash" unless vars.is_a?(Hash)

        request = Busybee::GRPC::SetVariablesRequest.new(
          elementInstanceKey: element_instance_key.to_i,
          variables: JSON.generate(vars),
          local: local
        )

        with_retry do
          stub.set_variables(request).key
        end
      end

      # Resolve an incident.
      #
      # @param incident_key [Integer, String] The incident key to resolve
      # @return [Boolean] true if resolved
      # @raise [Busybee::GRPC::Error] if resolving the incident fails
      #
      # @example Resolve an incident
      #   client.resolve_incident(54321)
      #   # => true
      #
      def resolve_incident(incident_key)
        request = Busybee::GRPC::ResolveIncidentRequest.new(
          incidentKey: incident_key.to_i
        )

        with_retry do
          stub.resolve_incident(request)
          true
        end
      end
    end
  end
end
