# frozen_string_literal: true

require "rspec/expectations"

require "busybee/testing/no_jobs_available"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      # Matcher to check if jobs are available for activation.
      #
      # This matcher is designed to work with blocks that call `activate_job` or `activate_jobs`.
      # A block raising `Busybee::Testing::NoJobsAvailable` or returning an empty Array has found
      # no jobs. Any other error raises through it, in either form.
      #
      # @example Check that jobs are available
      #   expect { activate_job("process-order") }.to have_available_jobs
      #
      # @example Check that NO jobs are available (most common usage)
      #   expect { activate_job("process-order") }.not_to have_available_jobs
      #
      matcher :have_available_jobs do
        supports_block_expectations

        match do |block|
          block.call != []
        rescue Busybee::Testing::NoJobsAvailable => e
          @no_job_error = e
          false
        end

        failure_message do
          if @no_job_error
            "expected jobs to be available, but got #{@no_job_error.class}: #{@no_job_error.message}"
          else
            "expected jobs to be available, but none were activated"
          end
        end

        failure_message_when_negated do
          "expected no jobs to be available, but a job was activated"
        end
      end

      alias_matcher :have_an_available_job, :have_available_jobs
    end
  end
end
