# frozen_string_literal: true

require "busybee/error"

module Busybee
  module GRPC
    # Wraps GRPC::BadStatus errors with Ruby-friendly interface.
    # Preserves original error via automatic exception chaining.
    #
    # @example
    #   begin
    #     stub.some_call(request)
    #   rescue ::GRPC::BadStatus
    #     raise Busybee::GRPC::Error.new("Operation failed")
    #   end
    #
    class Error < Busybee::Error
      def initialize(message = "GRPC request failed")
        super
      end

      # Returns the error message, automatically incorporating GRPC error details.
      # If the cause is a GRPC::BadStatus, appends "(grpc_details)" to the message.
      def message
        base = super

        if cause.is_a?(::GRPC::BadStatus)
          "#{base} (#{cause.details})"
        else
          base
        end
      end

      # Returns the GRPC status code as an integer (e.g., 14 for Unavailable).
      # Returns nil if the cause is not a GRPC::BadStatus error.
      def grpc_code
        return nil unless cause.is_a?(::GRPC::BadStatus)

        cause.code
      end

      # Returns the GRPC status as a symbol (e.g., :unavailable).
      # Returns nil if the cause is not a GRPC::BadStatus error.
      def grpc_status
        return nil unless cause.is_a?(::GRPC::BadStatus)

        # GRPC::Unavailable -> :unavailable
        cause.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym
      end

      # Returns the GRPC error details string.
      # Returns nil if the cause is not a GRPC::BadStatus error.
      def grpc_details
        return nil unless cause.is_a?(::GRPC::BadStatus)

        cause.details
      end
    end
  end
end
