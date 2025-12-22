# frozen_string_literal: true

require "json"

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
    end
  end
end
