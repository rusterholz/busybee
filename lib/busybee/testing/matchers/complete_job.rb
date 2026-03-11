# frozen_string_literal: true

require "rspec/expectations"

# Asserts that a worker completes the job successfully.
#
# Checks that the job ends in +:complete+ status. Optionally checks
# the return value of +perform+ for expected variables via +with_vars+.
#
# @example Basic usage
#   job = build_test_job(variables: { order_id: 1 })
#   expect(MyWorker).to complete_job(job)
#
# @example With expected return variables
#   expect(MyWorker).to complete_job(job).with_vars(status: "done")
#
RSpec::Matchers.define :complete_job do |job|
  match do |worker_class|
    @result = execute_worker(worker_class, job: job)
    return false unless job.complete?

    if @expected_vars
      if @result.is_a?(Hash)
        values_match?(@expected_vars, @result)
      else
        @expected_vars == {}
      end
    else
      true
    end
  rescue StandardError => e
    @raised_error = e
    false
  end

  chain :with_vars do |expected|
    @expected_vars = expected
  end

  chain :with_no_vars do
    @expected_vars = {}
  end

  failure_message do
    if @raised_error
      "expected #{actual} to complete the job, but it raised " \
        "#{@raised_error.class}: #{@raised_error.message}"
    elsif !job.complete?
      "expected job to be complete, but was #{job.status}"
    else
      "expected result to match #{@expected_vars.inspect}, " \
        "got #{@result.inspect}"
    end
  end
end
