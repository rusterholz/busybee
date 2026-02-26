# frozen_string_literal: true

module Oms
  class MarkOrderPreparedWorker < Busybee::Worker
    description "Transitions an order to processing after shipments are planned"

    variable :order_id, type: :uuid, description: "Order to transition"

    def perform
      Order.transaction do
        Order.find(order_id).update!(status: "processing")
      end
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
