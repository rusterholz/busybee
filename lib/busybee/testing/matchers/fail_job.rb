# frozen_string_literal: true

require "rspec/expectations"

# Asserts that a worker fails the job with an optional error match.
#
# Accepts the same argument forms as RSpec's +raise_error+:
#   with_error(ErrorClass)
#   with_error(ErrorClass, "exact message")
#   with_error(ErrorClass, /message pattern/)
#   with_error("exact message")
#   with_error(/message pattern/)
#
# @example Basic usage
#   job = build_test_job(variables: { order_id: 999 })
#   expect(MyWorker).to fail_job(job)
#
# @example With error class
#   expect(MyWorker).to fail_job(job).with_error(ActiveRecord::RecordNotFound)
#
# @example With error class and message
#   expect(MyWorker).to fail_job(job).with_error(ArgumentError, /invalid/)
#
RSpec::Matchers.define :fail_job do |job|
  match do |worker_class|
    execute_worker(worker_class, job: job)
    @no_error = true
    false
  rescue StandardError => e
    @raised_error = e
    job.failed? && error_matches?(e)
  end

  chain :with_error do |expected_error_or_message, expected_message = nil|
    case expected_error_or_message
    when String, Regexp
      @expected_error = StandardError
      @expected_message = expected_error_or_message
    else
      @expected_error = expected_error_or_message
      @expected_message = expected_message
    end
  end

  def error_matches?(error)
    return true unless @expected_error

    class_matches = @expected_error === error # rubocop:disable Style/CaseEquality
    return false unless class_matches
    return true unless @expected_message

    case @expected_message
    when Regexp then error.message.match?(@expected_message)
    else error.message == @expected_message.to_s
    end
  end

  failure_message do
    if @no_error
      "expected #{actual} to fail the job, but it completed successfully"
    elsif !job.failed?
      "expected job to be failed, but was #{job.status}"
    else
      "expected error matching #{expected_description}, " \
        "got #{@raised_error.class}: #{@raised_error.message}"
    end
  end

  def expected_description
    parts = []
    parts << @expected_error.inspect if @expected_error
    parts << @expected_message.inspect if @expected_message
    parts.join(" with message ")
  end
end
