# frozen_string_literal: true

require_relative "busybee/version"
require_relative "busybee/defaults"

# Top-level gem module, only holds configuration values.
module Busybee
  class << self
    attr_writer :cluster_address, :grpc_retry_enabled, :grpc_retry_delay_ms, :grpc_retry_errors
    attr_accessor :logger

    def configure
      yield self
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

    private

    def default_retry_errors
      require "grpc"
      [::GRPC::Unavailable, ::GRPC::DeadlineExceeded, ::GRPC::ResourceExhausted]
    end
  end
end

require_relative "busybee/railtie" if defined?(Rails::Railtie)
