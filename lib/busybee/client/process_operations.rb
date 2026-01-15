# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  class Client
    # Process deployment, instance creation, and cancellation operations.
    module ProcessOperations
      # Deploy one or more BPMN files.
      #
      # @param paths [Array<String>] Paths to BPMN files
      # @param tenant_id [String, nil] Tenant ID for multi-tenancy
      # @return [Hash{String => Integer}] Map of bpmn_process_id => process_definition_key
      # @raise [Busybee::GRPC::Error] if deployment fails
      #
      # @example Deploy a single file
      #   client.deploy_process("workflows/order.bpmn")
      #   # => { "order-fulfillment" => 2251799813685249 }
      #
      # @example Deploy multiple files
      #   client.deploy_process("order.bpmn", "payment.bpmn")
      #   # => { "order-fulfillment" => 123, "payment-process" => 456 }
      #
      def deploy_process(*paths, tenant_id: nil)
        resources = paths.map do |path|
          Busybee::GRPC::Resource.new(
            name: File.basename(path),
            content: File.read(path)
          )
        end

        request = Busybee::GRPC::DeployResourceRequest.new(
          resources: resources,
          tenantId: tenant_id
        )

        with_retry do
          response = stub.deploy_resource(request)
          response.deployments.each_with_object({}) do |deployment, result|
            result[deployment.process.bpmnProcessId] = deployment.process.processDefinitionKey
          end
        end
      end

      # Start a process instance.
      #
      # @param bpmn_process_id [String] The BPMN process ID to start
      # @param vars [Hash] Variables to pass to the process instance
      # @param version [Integer, Symbol, nil] Process version (:latest, nil, or specific version number)
      # @param tenant_id [String, nil] Tenant ID for multi-tenancy
      # @return [Integer] The process_instance_key
      # @raise [ArgumentError] if vars is not a Hash
      # @raise [Busybee::GRPC::Error] if starting the process fails
      #
      # @example Start a process instance with variables
      #   key = client.start_instance("order-fulfillment", vars: { orderId: 123 })
      #   # => 67890
      #
      def start_instance(bpmn_process_id, vars: {}, version: :latest, tenant_id: nil)
        raise ArgumentError, "vars must be a Hash" unless vars.is_a?(Hash)

        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: bpmn_process_id,
          variables: JSON.generate(vars),
          version: version == :latest || version.nil? ? -1 : version,
          tenantId: tenant_id
        )

        with_retry do
          stub.create_process_instance(request).processInstanceKey
        end
      end
      alias start_process_instance start_instance

      # Cancel a running process instance.
      #
      # @param process_instance_key [Integer, String] The process instance key to cancel
      # @param ignore_missing [Boolean] If true, return false instead of raising when instance not found
      # @return [Boolean] true if cancelled, false if not found and ignore_missing is true
      # @raise [Busybee::GRPC::Error] if cancellation fails (unless ignore_missing for NotFound)
      #
      # @example Cancel an instance
      #   client.cancel_instance(67890)
      #   # => true
      #
      # @example Safely cancel without error if missing
      #   client.cancel_instance(99999, ignore_missing: true)
      #   # => false
      #
      def cancel_instance(process_instance_key, ignore_missing: false)
        request = Busybee::GRPC::CancelProcessInstanceRequest.new(
          processInstanceKey: process_instance_key.to_i
        )

        with_retry do
          stub.cancel_process_instance(request)
          true
        end
      rescue Busybee::GRPC::Error => e
        raise unless ignore_missing && e.grpc_status == :not_found

        false
      end
      alias cancel_process_instance cancel_instance
    end
  end
end
