# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  class Client
    # Message and signal operations for process communication.
    module MessageOperations
      # Publish a message to trigger message catch events in process instances.
      #
      # @param name [String] The message name
      # @param correlation_key [String] Correlation key to match against process instances
      # @param ttl [Integer, ActiveSupport::Duration] Time-to-live in milliseconds or Duration object
      # @param vars [Hash] Variables to pass with the message
      # @param tenant_id [String, nil] Tenant ID for multi-tenancy
      # @return [Integer] The message key
      # @raise [ArgumentError] if vars is not a Hash or ttl is nil
      # @raise [Busybee::GRPC::Error] if publishing fails
      #
      # @example Publish a message
      #   key = client.publish_message("order-ready", correlation_key: "order-123", ttl: 60_000)
      #   # => 12345
      #
      # @example With variables and Duration TTL
      #   client.publish_message("order-ready",
      #     correlation_key: "order-123",
      #     ttl: 30.seconds,
      #     vars: { orderId: 123 })
      #
      def publish_message(name, correlation_key:, ttl:, vars: {}, tenant_id: nil)
        raise ArgumentError, "ttl is required (message buffer time in milliseconds or Duration)" if ttl.nil?
        raise ArgumentError, "vars must be a Hash" unless vars.is_a?(Hash)

        ttl_ms = ttl.is_a?(ActiveSupport::Duration) ? ttl.in_milliseconds.to_i : ttl.to_i

        request = Busybee::GRPC::PublishMessageRequest.new(
          name: name.to_s,
          correlationKey: correlation_key.to_s,
          variables: JSON.generate(vars),
          timeToLive: ttl_ms,
          tenantId: tenant_id
        )

        with_retry do
          stub.publish_message(request).key
        end
      end

      # Broadcast a signal to all process instances with matching signal catch events.
      #
      # @param signal_name [String] The signal name
      # @param vars [Hash] Variables to pass with the signal
      # @param tenant_id [String, nil] Tenant ID for multi-tenancy
      # @return [Integer] The signal key
      # @raise [ArgumentError] if vars is not a Hash
      # @raise [Busybee::GRPC::Error] if broadcasting fails
      #
      # @example Broadcast a signal
      #   key = client.broadcast_signal("cancel-all-orders")
      #   # => 54321
      #
      # @example With variables
      #   client.broadcast_signal("cancel-all-orders", vars: { reason: "system-maintenance" })
      #
      def broadcast_signal(signal_name, vars: {}, tenant_id: nil)
        raise ArgumentError, "vars must be a Hash" unless vars.is_a?(Hash)

        request = Busybee::GRPC::BroadcastSignalRequest.new(
          signalName: signal_name.to_s,
          variables: JSON.generate(vars),
          tenantId: tenant_id
        )

        with_retry do
          stub.broadcast_signal(request).key
        end
      end
    end
  end
end
