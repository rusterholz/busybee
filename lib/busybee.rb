# frozen_string_literal: true

require_relative "busybee/version"
require_relative "busybee/defaults"
require_relative "busybee/credentials"
require_relative "busybee/logging"

# Top-level gem module, only holds configuration values.
module Busybee
  # Valid credential type identifiers. Update this as new credential classes are added.
  VALID_CREDENTIAL_TYPES = %w[insecure tls oauth camunda_cloud].freeze

  # Valid log format identifiers.
  VALID_LOG_FORMATS = %w[text json].freeze

  class << self
    attr_writer :cluster_address, :grpc_retry_enabled, :grpc_retry_delay_ms, :grpc_retry_errors
    attr_accessor :logger
    attr_reader :credentials

    def configure
      yield self
    end

    def log_format=(value)
      if value.nil?
        @log_format = nil
        return
      end

      str_value = value.to_s
      if VALID_LOG_FORMATS.include?(str_value)
        @log_format = str_value.to_sym
      else
        Logging.warn("Invalid log_format: #{str_value.inspect}. Valid formats: #{VALID_LOG_FORMATS.join(', ')}")
      end
    end

    def log_format
      @log_format || :text
    end

    def cluster_address
      @cluster_address || ENV.fetch("CLUSTER_ADDRESS", "localhost:26500")
    end

    def grpc_retry_enabled
      return @grpc_retry_enabled unless @grpc_retry_enabled.nil?

      false
    end

    def grpc_retry_delay_ms
      @grpc_retry_delay_ms || Defaults::DEFAULT_GRPC_RETRY_DELAY_MS
    end

    def grpc_retry_errors
      @grpc_retry_errors || default_retry_errors
    end

    def credential_type=(value)
      if value.nil?
        @credential_type = nil
        return
      end

      str_value = value.to_s
      if VALID_CREDENTIAL_TYPES.include?(str_value)
        @credential_type = str_value.to_sym
      else
        Logging.warn("Invalid credential_type: #{str_value.inspect}. Valid types: #{VALID_CREDENTIAL_TYPES.join(', ')}")
      end
    end

    def credential_type
      return @credential_type if instance_variable_defined?(:@credential_type) && !@credential_type.nil?

      # Env var fallback - goes through setter for validation
      env_value = ENV.fetch("BUSYBEE_CREDENTIAL_TYPE", nil)
      return nil if env_value.nil?

      self.credential_type = env_value
      @credential_type
    end

    def credentials=(value)
      if value.nil?
        @credentials = nil
        return
      end

      unless value.is_a?(Busybee::Credentials)
        raise ArgumentError, "credentials must be a Busybee::Credentials object, got #{value.class}"
      end

      @credentials = value
    end

    private

    def default_retry_errors
      require "grpc"
      [::GRPC::Unavailable, ::GRPC::DeadlineExceeded, ::GRPC::ResourceExhausted]
    end
  end
end

require_relative "busybee/railtie" if defined?(Rails::Railtie)
