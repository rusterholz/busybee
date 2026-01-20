# frozen_string_literal: true

require "securerandom"
require "base64"
require "json"
require "active_support"
require "active_support/duration"
require "busybee/grpc"
require_relative "activated_job"

module Busybee
  module Testing
    # Raised when no job is available for activation
    class NoJobAvailable < StandardError; end

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
      def deploy_process(path, uniquify: nil)
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

      # Create a process instance, yield its key, and cancel on block exit.
      #
      # @param process_name [String] BPMN process ID
      # @param variables [Hash] variables to start the process with
      # @yield [Integer] the process instance key
      def with_process_instance(process_name, variables = {})
        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: process_name,
          version: -1,
          variables: JSON.generate(variables)
        )

        response = grpc_client.create_process_instance(request)
        @current_process_instance_key = response.processInstanceKey

        yield @current_process_instance_key
      ensure
        if @current_process_instance_key
          cancel_process_instance(@current_process_instance_key)
          @last_process_instance_key = @current_process_instance_key
          @current_process_instance_key = nil
        end
      end

      # Returns the current process instance key (set by with_process_instance).
      #
      # @return [Integer, nil]
      def process_instance_key
        @current_process_instance_key
      end

      # Returns the last process instance key from the most recent with_process_instance call.
      # Useful for debugging failed tests by tying failures to residual data in ElasticSearch.
      #
      # @return [Integer, nil]
      def last_process_instance_key
        @last_process_instance_key
      end

      # Checks if Zeebe is available and responsive.
      #
      # This method attempts to connect to Zeebe and call the topology endpoint
      # to verify the service is running and healthy.
      #
      # @param timeout [Integer] timeout in seconds for the connection check
      # @return [Boolean] true if Zeebe is available, false otherwise
      def zeebe_available?(timeout: 5)
        request = Busybee::GRPC::TopologyRequest.new
        grpc_client.topology(request, deadline: Time.now + timeout)
        true
      rescue ::GRPC::Unavailable, ::GRPC::DeadlineExceeded, ::GRPC::Core::CallError, ::GRPC::Unauthenticated
        false
      end

      # Activate a single job of the given type.
      #
      # @param type [String] job type
      # @param timeout [Integer, nil] request timeout in milliseconds (defaults to Busybee::Testing.activate_request_timeout)
      # @return [ActivatedJob]
      # @raise [NoJobAvailable] if no job is available
      def activate_job(type, timeout: nil)
        jobs = activate_jobs_raw(type, max_jobs: 1, timeout: timeout)
        raise NoJobAvailable, "No job of type '#{type}' available" if jobs.empty?

        ActivatedJob.new(jobs.first, client: grpc_client)
      end

      # Activate multiple jobs of the given type.
      #
      # @param type [String] job type
      # @param max_jobs [Integer] maximum number of jobs to activate
      # @param timeout [Integer, nil] request timeout in milliseconds (defaults to Busybee::Testing.activate_request_timeout)
      # @return [Enumerator<ActivatedJob>]
      def activate_jobs(type, max_jobs:, timeout: nil)
        Enumerator.new do |yielder|
          activate_jobs_raw(type, max_jobs: max_jobs, timeout: timeout).each do |raw_job|
            yielder << ActivatedJob.new(raw_job, client: grpc_client)
          end
        end
      end

      # Publish a message to Zeebe.
      #
      # @param name [String] message name
      # @param correlation_key [String] correlation key
      # @param variables [Hash] message variables
      # @param ttl_ms [Integer] time-to-live in milliseconds
      def publish_message(name, correlation_key:, variables: {}, ttl_ms: 5000)
        request = Busybee::GRPC::PublishMessageRequest.new(
          name: name,
          correlationKey: correlation_key,
          variables: JSON.generate(variables),
          timeToLive: ttl_ms
        )
        grpc_client.publish_message(request)
      end

      # Set variables on a process scope.
      #
      # @param scope_key [Integer] element instance key
      # @param variables [Hash] variables to set
      # @param local [Boolean] whether variables are local to scope
      def set_variables(scope_key, variables, local: true)
        request = Busybee::GRPC::SetVariablesRequest.new(
          elementInstanceKey: scope_key,
          variables: JSON.generate(variables),
          local: local
        )
        grpc_client.set_variables(request)
      end

      # Assert that the current process instance has completed.
      #
      # @param wait [Float] seconds to wait before checking
      # @raise [RuntimeError] if process is still running
      def assert_process_completed!(wait: 0.25)
        sleep(wait) if wait.positive?

        request = Busybee::GRPC::CancelProcessInstanceRequest.new(
          processInstanceKey: process_instance_key
        )

        begin
          grpc_client.cancel_process_instance(request)
        rescue ::GRPC::NotFound
          true # Expected - process has completed
        else
          raise "Process instance #{process_instance_key} is still running (expected it to be completed)"
        end
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
        bpmn_content.
          gsub(/(<bpmn:process id=")[^"]+/, "\\1#{process_id}").
          # Possessive quantifiers (++, *+) prevent polynomial backtracking
          gsub(/(<bpmndi:BPMNPlane\s++[^>]*+bpmnElement=")[^"]++/, "\\1#{process_id}")
      end

      def cancel_process_instance(key)
        request = Busybee::GRPC::CancelProcessInstanceRequest.new(
          processInstanceKey: key
        )
        grpc_client.cancel_process_instance(request)
        true
      rescue ::GRPC::NotFound
        # Process already completed, ignore
        false
      end

      def activate_jobs_raw(type, max_jobs:, timeout: nil)
        worker = "#{type}-#{SecureRandom.hex(4)}"

        request_timeout = timeout || Busybee::Testing.activate_request_timeout
        request_timeout_ms = if request_timeout.is_a?(ActiveSupport::Duration)
                               request_timeout.in_milliseconds.to_i
                             else
                               request_timeout.to_i
                             end

        request = Busybee::GRPC::ActivateJobsRequest.new(
          type: type,
          worker: worker,
          timeout: 30_000,
          maxJobsToActivate: max_jobs,
          requestTimeout: request_timeout_ms
        )

        jobs = []
        grpc_client.activate_jobs(request).each do |response|
          jobs.concat(response.jobs.to_a)
        end
        jobs
      end

      def grpc_client
        require "busybee/credentials"
        # Uses Busybee.credential_type if set, autodetects from env vars otherwise
        Busybee::Credentials.build.grpc_stub
      end
    end
  end
end
