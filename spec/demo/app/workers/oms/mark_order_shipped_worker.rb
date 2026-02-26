# frozen_string_literal: true

module Oms
  class MarkOrderShippedWorker < Busybee::Worker
    description "Transitions an order to shipping after all shipments are packed"

    variable :order_id, type: :uuid, description: "Order to transition"

    def perform
      Order.transaction do
        Order.find(order_id).update!(status: "shipping")
      end
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
