# frozen_string_literal: true

module Oms
  class UpdateOrderStatusWorker < Busybee::Worker
    description "Transitions an order to the status specified in the BPMN header"

    variable :order_id, type: :uuid, description: "Order to transition"
    header   :status,   type: :string, description: "Target order status (e.g. processing, packed, shipping, fulfilled)"

    ALLOWED_STATUSES = %w[processing packed shipping fulfilled].freeze

    def perform
      validate_status!

      order.update!(status: status)
      Rails.logger.info("Order ##{order.short_id} marked as #{status}")
    end

    private

    def order
      @order ||= Order.find(order_id)
    end

    def validate_status!
      return if ALLOWED_STATUSES.include?(status)

      raise ArgumentError, "Invalid order status: #{status.inspect}. Allowed: #{ALLOWED_STATUSES.join(', ')}"
    end
  end
end
