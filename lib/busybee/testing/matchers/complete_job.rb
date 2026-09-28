# frozen_string_literal: true

require "rspec/expectations"

# Asserts that a worker completes the job. Optionally checks the variables it
# completed with, via +with_vars+: the job's recorded result, which is what went
# to the engine. Runs the worker through
# {Busybee::Testing::Helpers::Execution#execute_worker}.
#
# @example Basic usage
#   job = build_test_job(variables: { order_id: 1 })
#   expect(MyWorker).to complete_job(job)
#
# @example With expected variables
#   expect(MyWorker).to complete_job(job).with_vars(status: "done")
#
RSpec::Matchers.define :complete_job do |job|
  match do |worker_class|
    execute_worker(worker_class, job: job)
    job.complete? && (@expected_vars.nil? || values_match?(@expected_vars, job.result || {}))
  end

  chain :with_vars do |expected|
    @expected_vars = expected
  end

  chain :with_no_vars do
    @expected_vars = {}
  end

  failure_message do
    if job.failed? && job.error
      "expected #{actual} to complete the job, but it raised " \
        "#{job.error.class}: #{job.error.message}"
    elsif !job.complete?
      "expected job to be complete, but was #{job.status}"
    else
      "expected result to match #{@expected_vars.inspect}, got #{job.result.inspect}"
    end
  end
end
