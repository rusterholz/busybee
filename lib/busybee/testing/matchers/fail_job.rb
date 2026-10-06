# frozen_string_literal: true

require "rspec/expectations"

module Busybee
  module Testing
    module Matchers
      extend RSpec::Matchers::DSL

      # Asserts that a worker fails the job, optionally matching the error it failed with.
      # Runs the worker through {Busybee::Testing::Helpers::Execution#execute_worker}.
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
      matcher :fail_job do |job|
        match do |worker_class|
          execute_worker(worker_class, job: job)
          job.failed? && error_matches?
        end

        chain :with_error do |expected_error_or_message, expected_message = nil|
          case expected_error_or_message
          when String, Regexp
            @expected_message = expected_error_or_message
          else
            @expected_error = expected_error_or_message
            @expected_message = expected_message
          end
        end

        def error_matches?
          return false if @expected_error && !(@expected_error === expected.error)
          return true unless @expected_message

          case @expected_message
          when Regexp then expected.error_message.to_s.match?(@expected_message)
          else expected.error_message == @expected_message.to_s
          end
        end

        failure_message do
          if job.complete? && job.error.nil?
            "expected #{actual} to fail the job, but it completed successfully"
          elsif !job.failed?
            "expected job to be failed, but was #{job.status}"
          else
            "expected error matching #{expected_description}, got #{actual_description}"
          end
        end

        def expected_description
          [@expected_error&.inspect, @expected_message&.inspect].compact.join(" with message ")
        end

        def actual_description
          error = expected.error
          error ? "#{error.class}: #{error.message}" : expected.error_message.inspect
        end
      end
    end
  end
end
