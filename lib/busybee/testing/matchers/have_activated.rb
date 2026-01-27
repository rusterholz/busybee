# frozen_string_literal: true

require "rspec/expectations"
require "busybee/testing/activated_job"

RSpec::Matchers.define :have_activated do |job_type|
  match do |helper|
    @job_type = job_type
    @helper = helper

    begin
      @activated_job = helper.activate_job(job_type)
      @job_activated = true
    rescue Busybee::Testing::NoJobAvailable
      @job_activated = false
      return false
    end

    # If we have chained expectations, validate them
    if @expected_variables
      expected_stringified = @expected_variables.transform_keys(&:to_s)
      actual = @activated_job.variables
      unless actual.slice(*expected_stringified.keys) == expected_stringified
        @variables_mismatch = true
        @actual_variables = actual
        return false
      end
    end

    if @expected_headers
      expected_stringified = @expected_headers.transform_keys(&:to_s)
      actual = @activated_job.headers
      unless actual.slice(*expected_stringified.keys) == expected_stringified
        @headers_mismatch = true
        @actual_headers = actual
        return false
      end
    end

    true
  end

  chain :with_variables do |expected|
    @expected_variables = expected
  end

  chain :with_headers do |expected|
    @expected_headers = expected
  end

  failure_message do
    if !@job_activated
      "No job of type '#{@job_type}' was activated"
    elsif @variables_mismatch
      "expected job variables to include #{@expected_variables.inspect}\n" \
        "actual variables: #{@actual_variables.inspect}"
    elsif @headers_mismatch
      "expected job headers to include #{@expected_headers.inspect}\n" \
        "actual headers: #{@actual_headers.inspect}"
    end
  end

  failure_message_when_negated do
    "expected no job of type '#{@job_type}' to be activated, but one was"
  end
end
