# frozen_string_literal: true

require "socket"
require "busybee/version"
require "busybee/defaults"
require "busybee/configure"
require "busybee/credentials"
require "busybee/logging"
require "busybee/serialization"
require "busybee/job"
require "busybee/job_stream"
require "busybee/client"
require "busybee/worker"
require "busybee/runtime_config"
require "busybee/runner"
require "busybee/cli"
require "busybee/hooks"

# Top-level gem module. Configuration readers and defaults live here;
# validated setters live in Busybee::Configure.
module Busybee
  # Valid credential type identifiers. Update this as new credential classes are added.
  VALID_CREDENTIAL_TYPES = %w[insecure tls oauth camunda_cloud].freeze

  # Valid log format identifiers.
  VALID_LOG_FORMATS = %w[text json].freeze

  # Valid worker mode identifiers.
  VALID_WORKER_MODES = %i[polling streaming hybrid].freeze

  class << self
    include Configure

    attr_accessor :logger
    attr_reader :credentials

    # Delegate hook registration methods to Busybee::Hooks
    Hooks::HOOK_TYPES.each do |type|
      define_method(type) do |**filters, &callback|
        Hooks.register(type, callback, **filters)
      end
    end

    def configure
      yield self
    end

    def cluster_address
      @cluster_address || ENV.fetch("CLUSTER_ADDRESS", "localhost:26500")
    end

    def credential_type
      return @credential_type if instance_variable_defined?(:@credential_type) && !@credential_type.nil?

      # Env var fallback - goes through setter for validation
      env_value = ENV.fetch("BUSYBEE_CREDENTIAL_TYPE", nil)
      return nil if env_value.nil?

      self.credential_type = env_value
      @credential_type
    end

    def default_fail_job_backoff
      @default_fail_job_backoff || Defaults::DEFAULT_FAIL_JOB_BACKOFF_MS
    end

    def default_max_jobs
      @default_max_jobs || Defaults::DEFAULT_MAX_JOBS
    end

    def default_input_required
      @default_input_required.nil? ? Defaults::DEFAULT_INPUT_REQUIRED : @default_input_required
    end

    def default_job_lock_timeout
      @default_job_lock_timeout || Defaults::DEFAULT_JOB_LOCK_TIMEOUT_MS
    end

    def default_job_request_timeout
      @default_job_request_timeout || Defaults::DEFAULT_JOB_REQUEST_TIMEOUT_MS
    end

    def default_message_ttl
      @default_message_ttl || Defaults::DEFAULT_MESSAGE_TTL_MS
    end

    def default_output_required
      @default_output_required.nil? ? Defaults::DEFAULT_OUTPUT_REQUIRED : @default_output_required
    end

    def default_strict_outputs
      @default_strict_outputs.nil? ? Defaults::DEFAULT_STRICT_OUTPUTS : @default_strict_outputs
    end

    def default_buffer
      @default_buffer.nil? ? Defaults::DEFAULT_STREAMING_BUFFER : @default_buffer
    end

    def default_buffer_throttle
      @default_buffer_throttle || Defaults::DEFAULT_BUFFER_THROTTLE_MS
    end

    def default_worker_mode
      @default_worker_mode || Defaults::DEFAULT_WORKER_MODE
    end

    def grpc_retry_delay_ms
      @grpc_retry_delay_ms || Defaults::DEFAULT_GRPC_RETRY_DELAY_MS
    end

    def grpc_retry_enabled
      return @grpc_retry_enabled unless @grpc_retry_enabled.nil?

      false
    end

    def grpc_retry_errors
      @grpc_retry_errors || default_retry_errors
    end

    # gRPC outcomes (status symbols, not classes) that signify gateway
    # backpressure — the runner backs off and retries the fetch when a call
    # resolves to one of these. Class-independent by design: it names the
    # outcome, not the exception type. (grpc_retry_errors, by contrast, is the
    # transient-class set the legacy retry mechanic consumes.)
    def backpressure_statuses
      @backpressure_statuses || Defaults::DEFAULT_BACKPRESSURE_STATUSES
    end

    def log_format
      @log_format || :text
    end

    def default_backpressure_delay
      @default_backpressure_delay || Defaults::DEFAULT_BACKPRESSURE_DELAY_MS
    end

    def shutdown_on_errors
      @shutdown_on_errors ||= []
    end

    def worker_name
      return @worker_name if @worker_name
      return ENV["BUSYBEE_WORKER_NAME"] if ENV["BUSYBEE_WORKER_NAME"]

      Socket.gethostname
    rescue StandardError
      "busybee-worker"
    end

    private

    def default_retry_errors
      require "grpc"
      [::GRPC::Unavailable, ::GRPC::DeadlineExceeded, ::GRPC::ResourceExhausted]
    end
  end
end

require "busybee/railtie" if defined?(Rails::Railtie)
