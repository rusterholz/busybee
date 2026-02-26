# frozen_string_literal: true

module Oms
  class MarkOrderFulfilledWorker < Busybee::Worker
    description "Transitions an order to fulfilled after all shipments are delivered"

    variable :order_id, type: :uuid, description: "Order to transition"

    def perform
      Order.transaction do
        Order.find(order_id).update!(status: "fulfilled")
      end
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
