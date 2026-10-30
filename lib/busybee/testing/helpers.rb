# frozen_string_literal: true

require "grpc"

require "busybee/durations"
require "busybee/grpc"
require "busybee/serialization"
require "busybee/testing/activated_job"
require "busybee/testing/foreign_jobs"
require "busybee/testing/helpers/builders"
require "busybee/testing/helpers/execution"
require "busybee/testing/helpers/hook_firing"
require "busybee/testing/helpers/hook_scoping"
require "busybee/testing/helpers/support"
require "busybee/testing/matchers/complete_job"
require "busybee/testing/matchers/fail_job"
require "busybee/testing/matchers/have_available_jobs"
require "busybee/testing/matchers/have_received_headers"
require "busybee/testing/matchers/have_received_variables"
require "busybee/testing/matchers/throw_bpmn_error_on"
require "busybee/testing/no_job_available"
require "busybee/testing/timings"

module Busybee
  module Testing
    # RSpec helper methods and matchers for testing BPMN workflows against
    # Zeebe, and the workers and hooks that serve them. busybee/testing includes
    # them into examples tagged :busybee.
    module Helpers
      extend Support
      include Builders
      include Execution
      include HookFiring
      include HookScoping
      include Matchers

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
          process_id = uniquify == true ? Busybee::Testing::Helpers.unique_process_id : uniquify
          bpmn_content = Busybee::Testing::Helpers.bpmn_with_unique_id(path, process_id)
        else
          bpmn_content = File.read(path)
          process_id = Busybee::Testing::Helpers.extract_process_id(bpmn_content)
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

      # Create a process instance, yield its key, and cancel it on block exit.
      # Blocks nest: each cancels its own instance, and the enclosing block's
      # instance is current again once an inner block ends.
      #
      # @param process_name [String] BPMN process ID
      # @param variables [Hash] variables to start the process with
      # @yield [Integer] the process instance key
      def with_process_instance(process_name, variables = {})
        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: process_name,
          version: -1,
          variables: Busybee::Serialization.to_json(variables)
        )

        key = grpc_client.create_process_instance(request).processInstanceKey
        busybee_process_instances.push(key)

        yield key
      rescue Exception # rubocop:disable Lint/RescueException
        failed = true
        raise
      ensure
        if key
          busybee_process_instances.delete(key)
          @last_process_instance_key = key
          Busybee::Testing::Helpers.cancel_process_instance(key, after_failure: failed)
        end
      end

      # Returns the current process instance key: the innermost
      # with_process_instance block's.
      #
      # @return [Integer, nil]
      def process_instance_key
        busybee_process_instances.last
      end

      # Returns the last process instance key from the most recent with_process_instance call.
      # Useful for debugging failed tests by tying failures to residual data in ElasticSearch.
      #
      # @return [Integer, nil]
      def last_process_instance_key
        @last_process_instance_key
      end

      # Activate a job, yield it, and complete it on block exit.
      # Must be called within a with_process_instance block.
      #
      # @param job_type [String] job type to activate
      # @yield [ActivatedJob] the activated job
      def with_activated_job_instance(job_type)
        job = activate_job(job_type)
        yield job
      ensure
        if job
          begin
            grpc_client.complete_job(Busybee::GRPC::CompleteJobRequest.new(jobKey: job.key, variables: "{}"))
          rescue ::GRPC::BadStatus
            # Job may have already been completed/failed in the test block - ignore
          end
        end
      end

      # Checks if Zeebe is available and responsive.
      #
      # This method attempts to connect to Zeebe and call the topology endpoint
      # to verify the service is running and healthy.
      #
      # @param wait [Numeric] seconds to allow for the connection check. Seconds,
      #   because it is spelled `wait:` — the gem's one seconds-grained parameter
      #   name, reserved for local waits in a test process. Every other duration
      #   input, including the ones on these helpers, is milliseconds.
      # @return [Boolean] true if Zeebe is available, false otherwise
      def zeebe_available?(wait: 5)
        request = Busybee::GRPC::TopologyRequest.new
        grpc_client.topology(request, deadline: Time.now + wait)
        true
      rescue ::GRPC::Unavailable, ::GRPC::DeadlineExceeded, ::GRPC::Core::CallError, ::GRPC::Unauthenticated
        false
      end

      # Activate a single job of the given type. Inside with_process_instance,
      # a job of any other process instance is handed back to the engine
      # unworked, and the wait goes on (see Testing.accepting_foreign_jobs).
      #
      # @param type [String] job type
      # @param timeout [Integer, ActiveSupport::Duration, nil] how long to wait
      #   for a job (defaults to Testing::ACTIVATE_JOB_TIMEOUT_MS)
      # @return [ActivatedJob]
      # @raise [NoJobAvailable] if no job is available
      def activate_job(type, timeout: nil)
        foreign = busybee_foreign_jobs
        jobs, refused = Busybee::Testing::Helpers.activate_own_jobs(type, max_jobs: 1, timeout: timeout,
                                                                          foreign: foreign)
        raise NoJobAvailable, foreign.no_job_message(type, refused) if jobs.empty?

        ActivatedJob.new(jobs.first, client: grpc_client)
      end

      # Activate multiple jobs of the given type, handing back foreign ones as
      # activate_job does.
      #
      # @param type [String] job type
      # @param max_jobs [Integer] maximum number of jobs to activate
      # @param timeout [Integer, ActiveSupport::Duration, nil] how long to wait
      #   for jobs (defaults to Testing::ACTIVATE_JOB_TIMEOUT_MS)
      # @return [Enumerator<ActivatedJob>]
      def activate_jobs(type, max_jobs:, timeout: nil)
        foreign = busybee_foreign_jobs
        Enumerator.new do |yielder|
          Busybee::Testing::Helpers.activate_own_jobs(type, max_jobs: max_jobs, timeout: timeout,
                                                            foreign: foreign).first.each do |raw_job|
            yielder << ActivatedJob.new(raw_job, client: grpc_client)
          end
        end
      end

      # Publish a message to Zeebe.
      #
      # @param name [String] message name
      # @param correlation_key [String] correlation key
      # @param vars [Hash] message variables
      # @param ttl [Integer, ActiveSupport::Duration] time-to-live
      #   (defaults to Testing::PUBLISH_MESSAGE_TTL_MS)
      def publish_message(name, correlation_key:, vars: {}, ttl: PUBLISH_MESSAGE_TTL_MS)
        ttl_ms = Busybee::Durations.milliseconds_from(ttl)
        request = Busybee::GRPC::PublishMessageRequest.new(
          name: name,
          correlationKey: correlation_key,
          variables: Busybee::Serialization.to_json(vars),
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
          variables: Busybee::Serialization.to_json(variables),
          local: local
        )
        grpc_client.set_variables(request)
      end

      # Assert that the current process instance has completed.
      #
      # @param wait [Numeric] seconds to wait before checking (see zeebe_available?
      #   for why `wait:` is the one parameter name that means seconds)
      # @raise [RuntimeError] if process is still running, or if called outside
      #   with_process_instance, where there is no instance to check
      def assert_process_completed!(wait: 0.25)
        unless process_instance_key
          raise "No current process instance: call assert_process_completed! inside with_process_instance"
        end

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

      # Returns a GRPC client stub for direct Zeebe access.
      # Uses Busybee.credential_type if set, autodetects from env vars otherwise.
      #
      # This is a public instance method that delegates to the module-level implementation.
      #
      # @return [Busybee::GRPC::Gateway::Stub]
      def grpc_client
        Busybee::Testing::Helpers.grpc_client
      end

      private

      # Keys of the with_process_instance blocks the example is inside, outermost first.
      def busybee_process_instances = @busybee_process_instances ||= []

      def busybee_foreign_jobs
        ForeignJobs.new(busybee_process_instances, accepting: Busybee::Testing.accepting_foreign_jobs?)
      end
    end
  end
end
