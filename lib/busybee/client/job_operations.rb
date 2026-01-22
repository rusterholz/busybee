# frozen_string_literal: true

require "active_support"
require "active_support/duration"
require "json"
require "busybee/grpc"

module Busybee
  class Client
    # Job completion, failure, and error throwing operations.
    module JobOperations
      # Complete a job with optional output variables.
      #
      # @param job_key [Integer] The unique job identifier
      # @param vars [Hash] Variables to return to the workflow engine
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if completion fails
      #
      # @example Complete a job without variables
      #   client.complete_job(123456)
      #
      # @example Complete a job with variables
      #   client.complete_job(123456, vars: { result: "success", orderId: 999 })
      #
      def complete_job(job_key, vars: {})
        request = Busybee::GRPC::CompleteJobRequest.new(
          jobKey: job_key.to_i,
          variables: vars.to_json
        )

        with_retry do
          stub.complete_job(request)
        end
      end

      # Fail a job with an error message.
      #
      # @param job_key [Integer] The unique job identifier
      # @param error_message [String] Error message describing the failure
      # @param retries [Integer, nil] Override the number of remaining retries
      # @param backoff [Integer, ActiveSupport::Duration, nil] Delay before retry in milliseconds
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if failure operation fails
      #
      # @example Fail a job with default backoff
      #   client.fail_job(123456, "Payment gateway timeout")
      #
      # @example Fail with custom retry count
      #   client.fail_job(123456, "Transient error", retries: 3)
      #
      # @example Fail with custom backoff duration
      #   client.fail_job(123456, "Rate limited", backoff: 30.seconds)
      #
      def fail_job(job_key, error_message, retries: nil, backoff: nil)
        backoff_ms = backoff || Busybee.default_fail_job_backoff
        backoff_ms = backoff_ms.is_a?(ActiveSupport::Duration) ? backoff_ms.in_milliseconds.to_i : backoff_ms.to_i

        request = Busybee::GRPC::FailJobRequest.new(
          jobKey: job_key.to_i,
          errorMessage: error_message.to_s,
          retryBackOff: backoff_ms
        )

        request.retries = retries.to_i if retries

        with_retry do
          stub.fail_job(request)
        end
      end

      # Throw a BPMN error to be caught by an error boundary event.
      #
      # @param job_key [Integer] The unique job identifier
      # @param error_code [String] BPMN error code (typically UPPERCASE_SNAKE_CASE)
      # @param message [String] Optional error message for context
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if throw operation fails
      #
      # @example Throw a BPMN error
      #   client.throw_bpmn_error(123456, "ORDER_NOT_FOUND", message: "Order 550e8400 not found")
      #
      # @example Throw a BPMN error without message
      #   client.throw_bpmn_error(123456, "PAYMENT_FAILED")
      #
      def throw_bpmn_error(job_key, error_code, message: "")
        request = Busybee::GRPC::ThrowErrorRequest.new(
          jobKey: job_key.to_i,
          errorCode: error_code.to_s,
          errorMessage: message.to_s
        )

        with_retry do
          stub.throw_error(request)
        end
      end
    end
  end
end
