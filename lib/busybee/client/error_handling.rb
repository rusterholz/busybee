# frozen_string_literal: true

require "busybee"
require "busybee/grpc/error"

module Busybee
  class Client
    # Provides GRPC error wrapping and optional retry logic.
    module ErrorHandling
      # Execute a block with optional GRPC retry and error wrapping.
      # @yield Block that makes GRPC call
      # @return Result of the block
      # @raise [Busybee::GRPC::Error] Wrapped GRPC error
      def with_retry
        attempts = 0
        max_attempts = Busybee.grpc_retry_enabled ? 2 : 1

        begin
          attempts += 1
          yield
        rescue *Busybee.grpc_retry_errors => e
          if attempts < max_attempts
            Busybee.logger&.warn("GRPC call failed (#{e.class.name}), retrying in #{Busybee.grpc_retry_delay_ms}ms...")
            sleep(Busybee.grpc_retry_delay_ms / 1000.0)
            retry
          end
          message = attempts > 1 ? "GRPC call failed after retry" : "GRPC call failed"
          raise Busybee::GRPC::Error, message
        rescue ::GRPC::BadStatus => e
          raise Busybee::GRPC::Error, "GRPC call failed"
        end
      end
    end
  end
end
