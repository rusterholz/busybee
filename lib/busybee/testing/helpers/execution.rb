# frozen_string_literal: true

require "busybee/testing/helpers/builders"

module Busybee
  module Testing
    module Helpers
      # Executes workers without a Zeebe connection; the job comes from Builders,
      # included alongside this module into Helpers, which busybee/testing
      # auto-includes into every RSpec example.
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
        # Execute a worker's full lifecycle against a test job.
        #
        # Runs the real Worker.perform_job — validation, perform, auto-resolution
        # all as in production. The one difference: errors re-raise after
        # handle_failure, so +raise_error+ and +be_failed+ can both be asserted.
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
      end
    end
  end
end
