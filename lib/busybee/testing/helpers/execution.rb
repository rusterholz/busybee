# frozen_string_literal: true

require "busybee/testing/helpers/builders"
require "busybee/testing/runner"

module Busybee
  module Testing
    module Helpers
      # Executes workers without a Zeebe connection, through the real runner
      # lifecycle; see Testing::Runner. The job comes from Builders, included
      # alongside this module into Helpers, which busybee/testing auto-includes
      # into every RSpec example.
      #
      # @example Happy path
      #   job = execute_worker(ProcessOrderWorker, variables: { order_id: order.id })
      #   expect(job).to be_complete
      #   expect(job.result).to eq("status" => "processed")
      #
      # @example Inspect a failure
      #   job = execute_worker(ProcessOrderWorker, variables: { order_id: 999 })
      #   expect(job).to be_failed
      #   expect(job.error).to be_a(ActiveRecord::RecordNotFound)
      #
      module Execution
        # Given a worker class, the worker starts, runs the jobs and stops, so every
        # hook level fires; given a started worker ({Builders#start_test_worker}), no
        # worker hook fires. A failed job keeps its error on +job.error+.
        #
        # @overload execute_worker(worker, **job_attrs)
        #   Build one job of the worker's type from {Builders#build_test_job}'s keywords.
        #   @return [Busybee::Job]
        # @overload execute_worker(worker, job:)
        #   @param job [Busybee::Job] built with {Builders#build_test_job}
        #   @return [Busybee::Job] that job
        # @overload execute_worker(worker, jobs:)
        #   @param jobs [Array<Busybee::Job>] built on one client
        #   @return [Array<Busybee::Job>] those jobs
        # @param worker [Class<Busybee::Worker>, Busybee::Testing::Runner]
        # @raise [ArgumentError] when more than one of job:, jobs: and keywords is given
        def execute_worker(worker, job: nil, jobs: nil, **job_attrs)
          if [job, jobs, (job_attrs unless job_attrs.empty?)].compact.size > 1
            raise ArgumentError, "Pass only one of job:, jobs:, or build_test_job keywords"
          end

          batch = jobs || [job || build_test_job(type: worker_type(worker), client: worker_client(worker),
                                                 **job_attrs)]
          worker.is_a?(Busybee::Testing::Runner) ? worker.activate(batch) : run_test_worker(worker, batch)
          jobs || batch.first
        end

        private

        def run_test_worker(worker_class, batch)
          clients = batch.map(&:client).uniq(&:object_id)
          raise ArgumentError, "Jobs run by one worker must share the same client" if clients.size > 1

          test_worker = start_test_worker(worker_class, client: clients.first)
          begin
            test_worker.activate(batch)
          ensure
            test_worker.stop!
          end
        end

        def worker_type(worker) = worker_class_of(worker).job_type
        def worker_client(worker) = worker.is_a?(Busybee::Testing::Runner) ? worker.client : nil
        def worker_class_of(worker) = worker.is_a?(Busybee::Testing::Runner) ? worker.worker_class : worker
      end
    end
  end
end
