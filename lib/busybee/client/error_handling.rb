# frozen_string_literal: true

require "busybee/durations"
require "busybee/grpc/error"
require "busybee/logging"

module Busybee
  class Client
    # Retry logic for GRPC calls. Translation of raw GRPC errors into
    # Busybee::GRPC::Error happens per attempt in Client::Call#attempt, so this is
    # retry-only: it sees already-translated errors and decides retryability from
    # the wrapped cause.
    module ErrorHandling
      # Execute a block, retrying when it raises a retryable Busybee::GRPC::Error.
      # @yield Block that makes a (translated) GRPC call
      # @return Result of the block
      # @raise [Busybee::GRPC::Error] the block's error, re-raised as-is once
      #   retries are exhausted or when the error is not retryable
      def with_retry
        attempts = 0
        max_attempts = Busybee.grpc_retry_enabled ? 2 : 1

        begin
          attempts += 1
          yield
        rescue Busybee::GRPC::Error => e
          raise unless attempts < max_attempts && retryable?(e)

          delay = Busybee::Durations.seconds_from(Busybee.grpc_retry_delay)
          Busybee::Logging.warn("GRPC call failed, retrying in #{delay}s",
                                error_class: e.cause&.class&.name)
          sleep(delay)
          retry
        end
      end

      private

      # A translated GRPC error is retryable when its underlying cause is one of
      # the configured transient GRPC error classes.
      def retryable?(error)
        Busybee.grpc_retry_errors.any? { |klass| error.cause.is_a?(klass) }
      end
    end
  end
end
