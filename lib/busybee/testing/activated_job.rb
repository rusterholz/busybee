# frozen_string_literal: true

require "json"
require "rspec/matchers"

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

      def process_instance_key
        raw.processInstanceKey
      end

      def variables
        @variables ||= JSON.parse(raw.variables)
      end

      def headers
        @headers ||= JSON.parse(raw.customHeaders)
      end

      def retries
        raw.retries
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

      private

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end
    end
  end
end
