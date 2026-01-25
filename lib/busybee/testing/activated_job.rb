# frozen_string_literal: true

require "json"
require "rspec/matchers"
require "busybee/grpc"

module Busybee
  module Testing
    # Wrapper around a raw GRPC ActivatedJob providing a fluent API for testing.
    #
    # @example Fluent style
    #   activate_job("my_task")
    #     .expect_variables(order_id: "123")
    #     .and_complete(result: "success")
    #
    # @example Standalone style
    #   job = activate_job("my_task")
    #   expect(job).to have_received_variables(order_id: "123")
    #   job.mark_completed(result: "success")
    #
    class ActivatedJob
      include RSpec::Matchers

      attr_reader :raw, :client

      def initialize(raw_job, client:)
        @raw = raw_job
        @client = client
      end

      def key
        raw.key
      end

      def type
        raw.type
      end

      def process_instance_key
        raw.processInstanceKey
      end

      def bpmn_process_id
        raw.bpmnProcessId
      end

      def retries
        raw.retries
      end

      def deadline
        raw.deadline
      end

      def variables
        @variables ||= JSON.parse(raw.variables)
      end

      def headers
        @headers ||= JSON.parse(raw.customHeaders)
      end

      # Assert that job variables include the expected values.
      # Raises RSpec expectation failure if not matched.
      #
      # @param expected [Hash] expected variable key-value pairs
      # @return [self] for chaining
      def expect_variables(expected)
        expect(variables).to include(stringify_keys(expected))
        self
      end

      # Assert that job headers include the expected values.
      # Raises RSpec expectation failure if not matched.
      #
      # @param expected [Hash] expected header key-value pairs
      # @return [self] for chaining
      def expect_headers(expected)
        expect(headers).to include(stringify_keys(expected))
        self
      end

      # Complete the job with optional output variables.
      #
      # @param variables [Hash] variables to merge into process state
      # @return [self]
      def mark_completed(variables = {})
        request = Busybee::GRPC::CompleteJobRequest.new(
          jobKey: key,
          variables: JSON.generate(variables)
        )
        client.complete_job(request)
        self
      end

      alias and_complete mark_completed

      # Fail the job with optional message and retry count.
      #
      # @param message [String, nil] error message
      # @param retries [Integer] number of retries remaining
      # @return [self]
      def mark_failed(message = nil, retries: 0)
        request = Busybee::GRPC::FailJobRequest.new(
          jobKey: key,
          retries: retries,
          errorMessage: message || ""
        )
        client.fail_job(request)
        self
      end

      alias and_fail mark_failed

      # Throw a BPMN error event.
      #
      # @param code [String] BPMN error code
      # @param message [String, nil] error message
      # @return [self]
      def throw_error_event(code, message = nil)
        request = Busybee::GRPC::ThrowErrorRequest.new(
          jobKey: key,
          errorCode: code,
          errorMessage: message || ""
        )
        client.throw_error(request)
        self
      end

      alias and_throw_error_event throw_error_event

      # Update the job's retry count.
      #
      # @param count [Integer] new retry count
      # @return [self]
      def update_retries(count)
        request = Busybee::GRPC::UpdateJobRetriesRequest.new(
          jobKey: key,
          retries: count
        )
        client.update_job_retries(request)
        self
      end

      private

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end
    end
  end
end
