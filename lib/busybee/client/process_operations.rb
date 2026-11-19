# frozen_string_literal: true

require "busybee/grpc"
require "busybee/grpc/error"
require "busybee/serialization"

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
          tenantId: tenant_id&.to_s
        )

        response = run_hooked(:deploy_resource, request)
        response.deployments.to_h do |deployment|
          [deployment.process.bpmnProcessId, deployment.process.processDefinitionKey]
        end
      end

      # Start a process instance.
      #
      # @param bpmn_process_id [String] The BPMN process ID to start
      # @param vars [Hash] Variables to pass to the process instance
      # @param version [Integer, Symbol, nil] Process version (:latest, nil, or specific version number)
      # @param tenant_id [String, nil] Tenant ID for multi-tenancy
      # @param business_id [String, nil] Business ID for the new instance (Camunda 8.9+;
      #   an older gateway ignores it)
      # @return [Integer] The process_instance_key
      # @raise [ArgumentError] if vars is not a Hash
      # @raise [Busybee::GRPC::Error] if starting the process fails
      #
      # @example Start a process instance with variables
      #   key = client.start_instance("order-fulfillment", vars: { orderId: 123 })
      #   # => 67890
      #
      # @example Start a process instance with a business ID
      #   client.start_instance("order-fulfillment", business_id: "order-123")
      #
      def start_instance(bpmn_process_id, vars: {}, version: :latest, tenant_id: nil, business_id: nil)
        raise ArgumentError, "vars must be a Hash" unless vars.is_a?(Hash)

        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: bpmn_process_id.to_s,
          variables: Busybee::Serialization.to_json(vars),
          version: version == :latest || version.nil? ? -1 : version.to_i,
          tenantId: tenant_id&.to_s
        )
        request.businessId = business_id.to_s unless business_id.nil?

        run_hooked(:create_process_instance, request).processInstanceKey
      end
      alias start_process_instance start_instance

      # Cancel a running process instance.
      #
      # @param process_instance_key [Integer, String] The process instance key to cancel
      # @param ignore_missing [Boolean] If true, return false instead of raising when instance not found
      # @return [Boolean] true if canceled, false if not found and ignore_missing is true
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

        run_hooked(:cancel_process_instance, request)
        true
      rescue Busybee::GRPC::Error => e
        raise unless ignore_missing && e.grpc_status == :not_found

        false
      end
      alias cancel_process_instance cancel_instance

      # Assign a business ID to a running root process instance (Camunda 8.10+).
      #
      # @param process_instance_key [Integer, String] The process instance key
      # @param business_id [String] The business ID, up to 256 characters
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if the assignment fails: grpc_status
      #   :failed_precondition when the instance already has one or is a call
      #   activity's child, :not_found when it isn't active, :invalid_argument
      #   for an empty or overlong ID, :unimplemented on a gateway older than 8.10
      #
      # @example Assign a business ID
      #   client.assign_business_id(67890, "ORD-123")
      #
      def assign_business_id(process_instance_key, business_id)
        request = Busybee::GRPC::AssignProcessInstanceBusinessIdRequest.new(
          processInstanceKey: process_instance_key.to_i,
          businessId: business_id.to_s
        )

        run_hooked(:assign_process_instance_business_id, request)
      end
      alias assign_process_instance_business_id assign_business_id
    end
  end
end
