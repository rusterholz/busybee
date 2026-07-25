# frozen_string_literal: true

require "busybee/client"
require "busybee/grpc"
require "busybee/job"
require "busybee/serialization"

module Busybee
  module Testing
    module Helpers
      # Builds test jobs and executes workers without a Zeebe connection.
      #
      # Included into Busybee::Testing::Helpers, which is auto-included in all
      # RSpec examples when busybee/testing is required.
      #
      # @example Happy path
      #   result = execute_worker(
      #     ProcessOrderWorker,
      #     variables: { order_id: order.id }
      #   )
      #   expect(result).to eq(status: "processed")
      #
      # @example Inspect job status after failure
      #   job = build_test_job(variables: { order_id: 999 })
      #   expect {
      #     execute_worker(ProcessOrderWorker, job: job)
      #   }.to raise_error(ActiveRecord::RecordNotFound)
      #   expect(job).to be_failed
      #
      module Execution
        # Build a test job backed by a stub client.
        #
        # The returned Job behaves like a real job — variables and headers are
        # parsed, status tracking works, and all client operations (complete!,
        # fail!, throw_bpmn_error!, update_retries, update_timeout) succeed
        # silently through a stub client.
        #
        # @param type [String] job type (defaults to "test")
        # @param variables [Hash] process variables
        # @param headers [Hash] custom headers
        # @param bpmn_process_id [String] BPMN process ID
        # @param retries [Integer] retry count
        # @param key [Integer] job key; defaults to a random value. Pass
        #   explicitly when a test correlates the same job by key across
        #   multiple assertions or wants a stable identifier in failure output.
        # @return [Busybee::Job]
        def build_test_job(type: "test", variables: {}, headers: {}, # rubocop:disable Metrics/ParameterLists
                           bpmn_process_id: "test-process", retries: 3,
                           key: rand(100_000..999_999))
          client = stub_client
          raw_job = stub_raw_job(
            key: key,
            type: type,
            variables: variables,
            headers: headers,
            bpmn_process_id: bpmn_process_id,
            retries: retries
          )
          Busybee::Job.new(raw_job, client: client)
        end

        # Execute a worker's full lifecycle against a test job.
        #
        # Runs the real Worker.perform_job — input validation, perform, output
        # validation, auto-complete/auto-fail all execute as in production. The
        # only difference: errors are re-raised after handle_failure completes,
        # so you can use +expect { }.to raise_error+ alongside +expect(job).to be_failed+.
        #
        # @overload execute_worker(worker_class, variables: {}, headers: {},
        #   bpmn_process_id: "test-process", retries: 3)
        #   Build a test job from keyword arguments and execute.
        #   @param worker_class [Class<Busybee::Worker>] the worker class to test
        #   @param variables [Hash] process variables
        #   @param headers [Hash] custom headers
        #   @param bpmn_process_id [String] BPMN process ID
        #   @param retries [Integer] retry count
        #   @return [Object] the return value of the worker's +perform+ method
        #
        # @overload execute_worker(worker_class, job:)
        #   Execute with a pre-built test job (from build_test_job).
        #   @param worker_class [Class<Busybee::Worker>] the worker class to test
        #   @param job [Busybee::Job] a pre-built test job
        #   @return [Object] the return value of the worker's +perform+ method
        #
        def execute_worker(worker_class, job: nil, # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
                           variables: {}, headers: {},
                           bpmn_process_id: "test-process", retries: 3)
          if job
            unless variables.empty? && headers.empty? &&
                   bpmn_process_id == "test-process" && retries == 3
              raise ArgumentError,
                    "Cannot pass job: together with variables:, headers:, " \
                    "bpmn_process_id:, or retries:. Use build_test_job to " \
                    "pre-configure the job, or pass keyword arguments — not both."
            end
          else
            job = build_test_job(
              type: worker_class.job_type,
              variables: variables, headers: headers,
              bpmn_process_id: bpmn_process_id, retries: retries
            )
          end

          # Wrap handle_failure to re-raise after production logic runs.
          # This lets tests assert both error class AND job status.
          allow(worker_class).to(
            receive(:handle_failure).and_wrap_original do |m, *args|
              m.call(*args).tap { raise args[1] }
            end
          )

          worker_class.perform_job(job)
        end

        private

        def stub_client
          instance_double(
            Busybee::Client,
            complete_job: true,
            fail_job: true,
            throw_bpmn_error: true,
            update_job_retries: true,
            update_job_timeout: true
          )
        end

        def stub_raw_job(type:, variables:, headers:, bpmn_process_id:, retries:, key:) # rubocop:disable Metrics/ParameterLists
          # Plain double because protobuf generates field accessors dynamically
          # via descriptors, which instance_double can't verify against.
          double(
            "Busybee::GRPC::ActivatedJob",
            key: key,
            type: type,
            processInstanceKey: rand(100_000..999_999),
            bpmnProcessId: bpmn_process_id,
            elementId: "test-element",
            retries: retries,
            deadline: (Time.now.to_i + 300) * 1000,
            variables: Busybee::Serialization.to_json(variables),
            customHeaders: Busybee::Serialization.to_json(headers)
          )
        end
      end
    end
  end
end
