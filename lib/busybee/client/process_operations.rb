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
    end
  end
end
