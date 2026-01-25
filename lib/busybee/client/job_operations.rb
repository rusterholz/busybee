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

      # Update the retry count for a job.
      #
      # @param job_key [Integer] The unique job identifier
      # @param retries [Integer] The new number of retries
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if update operation fails
      #
      # @example Update job retries
      #   client.update_job_retries(123456, 5)
      #
      def update_job_retries(job_key, retries)
        request = Busybee::GRPC::UpdateJobRetriesRequest.new(
          jobKey: job_key.to_i,
          retries: retries.to_i
        )

        with_retry do
          stub.update_job_retries(request)
        end
      end

      # Update the timeout for a job.
      #
      # @param job_key [Integer] The unique job identifier
      # @param timeout [Integer, ActiveSupport::Duration] New timeout in milliseconds
      # @return [Object] Response from the gateway (truthy)
      # @raise [Busybee::GRPC::Error] if update operation fails
      #
      # @example Update job timeout with milliseconds
      #   client.update_job_timeout(123456, 30_000)
      #
      # @example Update job timeout with Duration
      #   client.update_job_timeout(123456, 30.seconds)
      #
      def update_job_timeout(job_key, timeout)
        timeout_ms = timeout.is_a?(ActiveSupport::Duration) ? timeout.in_milliseconds.to_i : timeout.to_i

        request = Busybee::GRPC::UpdateJobTimeoutRequest.new(
          jobKey: job_key.to_i,
          timeout: timeout_ms
        )

        with_retry do
          stub.update_job_timeout(request)
        end
      end

      # Activate and process jobs with a block (bounded, non-streaming).
      #
      # @param job_type [String] The job type to activate
      # @param max_jobs [Integer] Maximum number of jobs to activate
      # @param job_timeout [Integer, ActiveSupport::Duration] Job timeout in milliseconds
      # @param request_timeout [Integer, ActiveSupport::Duration] Request timeout in milliseconds
      # @yield [job] Yields each activated job to the block
      # @yieldparam job [Busybee::Job] The activated job
      # @return [Integer] Count of jobs processed
      # @raise [ArgumentError] if no block given
      # @raise [Busybee::GRPC::Error] if activation fails
      #
      # @example Process jobs
      #   client.with_each_job("send-email") do |job|
      #     send_email(job.variables.email, job.variables.subject)
      #     job.complete!
      #   end
      #
      def with_each_job(job_type, max_jobs: Busybee::Defaults::DEFAULT_MAX_JOBS, # rubocop:disable Metrics/AbcSize
                        job_timeout: Busybee::Defaults::DEFAULT_JOB_TIMEOUT_MS,
                        request_timeout: Busybee::Defaults::DEFAULT_JOB_REQUEST_TIMEOUT_MS)
        raise ArgumentError, "block required" unless block_given?

        request = Busybee::GRPC::ActivateJobsRequest.new(
          type: job_type.to_s,
          worker: Busybee.worker_name,
          maxJobsToActivate: max_jobs.to_i,
          timeout: milliseconds_from(job_timeout),
          requestTimeout: milliseconds_from(request_timeout)
        )

        count = 0
        responses = with_retry { stub.activate_jobs(request) }

        responses.each do |response|
          response.jobs.each do |raw_job|
            job = Busybee::Job.new(raw_job, client: self)
            yield job
            count += 1
          end
        end

        count
      end
    end
  end
end
