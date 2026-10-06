# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "rspec/expectations"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      # Asserts that a worker throws a BPMN error on the job, optionally matching the
      # code and message it threw, via +with_code+. Runs the worker through
      # {Busybee::Testing::Helpers::Execution#execute_worker}, so the throw goes out
      # through the real client and its call hooks fire.
      #
      # @example Basic usage
      #   job = build_test_job(variables: { order_id: 999 })
      #   expect(MyWorker).to throw_bpmn_error_on(job)
      #
      # @example With error code
      #   expect(MyWorker).to throw_bpmn_error_on(job).with_code(:not_found)
      #
      # @example With error code and message
      #   expect(MyWorker).to throw_bpmn_error_on(job).with_code(:not_found, message: /missing/)
      #
      matcher :throw_bpmn_error_on do |job|
        match do |worker_class|
          execute_worker(worker_class, job: job)
          job.error? && code_matches? && message_matches?
        end

        chain :with_code do |expected_code, opts = {}|
          @expected_code = case expected_code
                           when Symbol then expected_code.to_s.upcase
                           when Class then expected_code.name.gsub("::", "_").underscore.upcase
                           else expected_code
                           end
          @expected_message = opts[:message]
        end

        def code_matches?
          return true unless @expected_code

          values_match?(@expected_code, expected.error_code)
        end

        def message_matches?
          return true unless @expected_message

          values_match?(@expected_message, expected.error_message)
        end

        failure_message do
          if job.failed? && job.error
            "expected #{actual} to throw a BPMN error, but it raised " \
              "#{job.error.class}: #{job.error.message}"
          elsif !job.error?
            "expected job to be error, but was #{job.status}"
          elsif @expected_code && !code_matches?
            "expected BPMN error code #{@expected_code.inspect}, got #{job.error_code.inspect}"
          else
            "expected BPMN error message #{@expected_message.inspect}, got #{job.error_message.inspect}"
          end
        end
      end
    end
  end
end
