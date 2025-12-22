# frozen_string_literal: true

require "securerandom"
require "base64"
require "json"
require "busybee/grpc"
require_relative "activated_job"

module Busybee
  module Testing
    # RSpec helper methods for testing BPMN workflows against Zeebe.
    module Helpers
      # Deploy a BPMN process file to Zeebe.
      #
      # By default, deploys the BPMN file as-is using its original process ID.
      # Optionally, you can uniquify the process ID for test isolation.
      #
      # @param path [String] path to BPMN file
      # @param uniquify [nil, true, String] uniquification behavior:
      #   - nil (default): deploy as-is with original process ID
      #   - true: auto-generate unique process ID like "test-process-abc123"
      #   - String: use provided string as custom process ID
      # @return [Hash] deployment info with keys:
      #   - :process [ProcessMetadata] - GRPC process metadata object
      #   - :process_id [String] - the BPMN process ID (uniquified or original)
      #
      # @example Deploy as-is (most common)
      #   result = deploy_process("path/to/process.bpmn")
      #   result[:process_id] #=> "simple-process" (from BPMN file)
      #
      # @example Deploy with auto-generated unique ID (for test isolation)
      #   result = deploy_process("path/to/process.bpmn", uniquify: true)
      #   result[:process_id] #=> "test-process-a1b2c3d4e5f6"
      #
      # @example Deploy with custom ID
      #   result = deploy_process("path/to/process.bpmn", uniquify: "my-test-process")
      #   result[:process_id] #=> "my-test-process"
      def deploy_process(path, uniquify: nil) # rubocop:disable Metrics/MethodLength
        if uniquify
          process_id = uniquify == true ? unique_process_id : uniquify
          bpmn_content = bpmn_with_unique_id(path, process_id)
        else
          bpmn_content = File.read(path)
          process_id = extract_process_id(bpmn_content)
        end

        resource = Busybee::GRPC::Resource.new(
          name: File.basename(path),
          content: bpmn_content
        )

        request = Busybee::GRPC::DeployResourceRequest.new(
          resources: [resource]
        )

        response = grpc_client.deploy_resource(request)

        {
          process: response.deployments.first.process,
          process_id: process_id
        }
      end

      private

      def unique_process_id
        "test-process-#{SecureRandom.hex(6)}"
      end

      def extract_process_id(bpmn_content)
        match = bpmn_content.match(/<bpmn:process id="([^"]+)"/)
        match ? match[1] : nil
      end

      def bpmn_with_unique_id(bpmn_path, process_id)
        bpmn_content = File.read(bpmn_path)
        bpmn_content
          .gsub(/(<bpmn:process id=")[^"]+/, "\\1#{process_id}")
          .gsub(/(<bpmndi:BPMNPlane\s+[^>]*bpmnElement=")[^"]+/, "\\1#{process_id}")
      end

      def grpc_client
        @grpc_client ||= Busybee::GRPC::Gateway::Stub.new(
          Busybee::Testing.address,
          :this_channel_is_insecure
        )
      end
    end
  end
end
