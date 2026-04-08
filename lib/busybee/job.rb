# frozen_string_literal: true

require "busybee/serialization"

module Busybee
  # Represents a job activated from Zeebe for processing by a worker.
  #
  # Wraps the raw GRPC ActivatedJob protobuf with a Ruby-idiomatic interface.
  # Tracks job status to prevent double-completion bugs.
  #
  # @example Complete a job
  #   job = Busybee::Job.new(raw_job, client: client)
  #   job.complete!(result: "success")
  #
  # @example Fail a job with retry
  #   job.fail!("Payment gateway timeout", retries: 3, backoff: 30.seconds)
  #
  # @example Throw a BPMN error
  #   job.throw_bpmn_error!(:order_not_found, "Order #{order_id} not found")
  #
  class Job
    attr_reader :client, :status

    TIMESTAMP_NAMES = %i[
      activated_at execution_started_at perform_started_at
      perform_finished_at resolved_at executed_at
    ].freeze

    TIMESTAMP_NAMES.each do |name|
      attr_reader name, :"#{name}_utc"
    end

    # Create a new Job wrapper.
    #
    # @param raw_job [Busybee::GRPC::ActivatedJob] The raw GRPC job protobuf
    # @param client [Busybee::Client] The client instance for completing/failing jobs
    def initialize(raw_job, client:)
      @raw_job = raw_job
      @client = client
      @status = :ready
    end

    # Stamp a lifecycle timestamp (monotonic + UTC pair).
    #
    # @param name [Symbol] one of TIMESTAMP_NAMES
    # @return [self]
    def stamp!(name)
      unless TIMESTAMP_NAMES.include?(name)
        raise ArgumentError, "Unknown timestamp: #{name}. Expected one of: #{TIMESTAMP_NAMES.join(', ')}"
      end

      instance_variable_set(:"@#{name}", Process.clock_gettime(Process::CLOCK_MONOTONIC))
      instance_variable_set(:"@#{name}_utc", Time.now.utc)
      self
    end

    # Job key (unique identifier)
    # @return [Integer]
    def key
      @raw_job.key
    end

    # Job type (task definition type from BPMN)
    # @return [String]
    def type
      @raw_job.type
    end

    # Process instance key
    # @return [Integer]
    def process_instance_key
      @raw_job.processInstanceKey
    end

    # BPMN process ID
    # @return [String]
    def bpmn_process_id
      @raw_job.bpmnProcessId
    end

    # Number of retries remaining
    # @return [Integer]
    def retries
      @retries_override || @raw_job.retries
    end

    # Job deadline as a frozen Time object
    # @return [Time]
    def deadline
      @deadline ||= Time.at(@raw_job.deadline / 1000.0).utc.freeze
    end

    # Job variables with indifferent access and method-style access.
    # Returns a frozen hash that supports both hash[:key] and hash.key access.
    # Nested hashes also support method access.
    #
    # @return [ActiveSupport::HashWithIndifferentAccess] frozen hash with method access
    def variables
      @variables ||= parse_and_freeze_hash(@raw_job.variables, "variables")
    end

    # Job custom headers with indifferent access and method-style access.
    # Returns a frozen hash that supports both hash[:key] and hash.key access.
    #
    # @return [ActiveSupport::HashWithIndifferentAccess] frozen hash with method access
    def headers
      @headers ||= parse_and_freeze_hash(@raw_job.customHeaders, "headers")
    end

    # Complete the job with optional output variables.
    #
    # @param vars [Hash] Variables to return to the workflow engine
    # @return [Object] Response from complete_job operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def complete!(vars = {})
      raise Busybee::JobAlreadyHandled, "Cannot complete job #{key} because it is already #{status}" unless ready?

      @client.complete_job(key, vars: vars).tap do
        @status = :complete
        # [hook: job.completed]
      end
    end

    # Fail the job with an error message.
    #
    # @param error_message_or_exception [String, Exception] Error message or exception
    # @param retries [Integer, nil] Override retry count
    # @param backoff [Integer, ActiveSupport::Duration, nil] Backoff before retry
    # @return [Object] Response from fail_job operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def fail!(error_message_or_exception, retries: nil, backoff: nil)
      raise Busybee::JobAlreadyHandled, "Cannot fail job #{key} because it is already #{status}" unless ready?

      message = format_error_message(error_message_or_exception)

      @client.fail_job(key, message, retries: retries, backoff: backoff).tap do
        @status = :failed
        # [hook: job.failed]
      end
    end

    # Throw a BPMN error to be caught by an error boundary event.
    #
    # @param code_or_exception [String, Symbol, Exception] Error code or exception
    # @param message [String] Optional error message
    # @return [Object] Response from throw_bpmn_error operation
    # @raise [Busybee::JobAlreadyHandled] if job has already been completed, failed, or errored
    def throw_bpmn_error!(code_or_exception, message = "")
      unless ready?
        raise Busybee::JobAlreadyHandled,
              "Cannot throw BPMN error on job #{key} because it is already #{status}"
      end

      code = format_error_code(code_or_exception)
      message = code_or_exception.message if code_or_exception.is_a?(Exception) && message.empty?

      @client.throw_bpmn_error(key, code, message: message).tap do
        @status = :error
        # [hook: job.error]
      end
    end

    # Update the retry count for this job.
    #
    # @param count [Integer] The new number of retries
    # @return [Object] Response from update_job_retries operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_retries(count)
      @client.update_job_retries(key, count).tap do
        @retries_override = count
      end
    end

    # Update the timeout for this job.
    #
    # @param duration [Integer, ActiveSupport::Duration] New timeout in milliseconds
    # @return [Object] Response from update_job_timeout operation
    # @raise [Busybee::GRPC::Error] if the update fails
    def update_timeout(duration)
      duration_seconds = duration.is_a?(ActiveSupport::Duration) ? duration.in_seconds : duration / 1000.0
      @client.update_job_timeout(key, duration).tap do
        @deadline = (Time.now.utc + duration_seconds).freeze
      end
    end

    # Is the job ready for processing?
    # @return [Boolean]
    def ready?
      status == :ready
    end

    # Has the job been completed?
    # @return [Boolean]
    def complete?
      status == :complete
    end

    # Has the job failed?
    # @return [Boolean]
    def failed?
      status == :failed
    end

    # Has the job thrown a BPMN error?
    # @return [Boolean]
    def error?
      status == :error
    end

    private

    def parse_and_freeze_hash(json_string, attribute_name)
      Busybee::Serialization.from_json(json_string)
    rescue Busybee::InvalidJobJson => e
      # Re-raise with attribute context for better error messages
      message = "Failed to parse job #{attribute_name}: #{e.cause.message}"
      raise Busybee::InvalidJobJson, message, e.backtrace, cause: e.cause
    end

    def format_error_message(error_message_or_exception)
      return error_message_or_exception unless error_message_or_exception.is_a?(Exception)

      message = "[#{error_message_or_exception.class.name}] #{error_message_or_exception.message}"
      if (cause = error_message_or_exception.cause)
        message += " (caused by: [#{cause.class.name}] #{cause.message})"
      end
      message
    end

    def format_error_code(code_or_exception)
      case code_or_exception
      when Symbol
        code_or_exception.to_s.upcase
      when Exception
        # Convert MyApp::Domain::OrderNotFoundError to MY_APP_DOMAIN_ORDER_NOT_FOUND_ERROR
        code_or_exception.class.name.gsub("::", "_").underscore.upcase
      else
        code_or_exception.to_s
      end
    end
  end
end
