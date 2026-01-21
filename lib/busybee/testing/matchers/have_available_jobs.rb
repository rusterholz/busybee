# frozen_string_literal: true

require "rspec/expectations"

# Matcher to check if jobs are available for activation.
#
# This matcher is designed to work with blocks that call `activate_job` or similar methods
# that raise `Busybee::Testing::NoJobAvailable` when no jobs are found.
#
# @example Check that jobs are available
#   expect { activate_job("process-order") }.to have_available_jobs
#
# @example Check that NO jobs are available (most common usage)
#   expect { activate_job("process-order") }.not_to have_available_jobs
#
RSpec::Matchers.define :have_available_jobs do
  supports_block_expectations

  match do |block|
    block.call
    @job_found = true
    true
  rescue Busybee::Testing::NoJobAvailable
    @job_found = false
    false
  rescue StandardError => e
    @unexpected_error = e
    false
  end

  failure_message do
    if @unexpected_error
      "expected jobs to be available, but got #{@unexpected_error.class}: #{@unexpected_error.message}"
    else
      "expected jobs to be available, but no jobs were found (Busybee::Testing::NoJobAvailable raised)"
    end
  end

  failure_message_when_negated do
    "expected no jobs to be available, but a job was activated"
  end
end

RSpec::Matchers.alias_matcher :have_an_available_job, :have_available_jobs
