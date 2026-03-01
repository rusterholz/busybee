# frozen_string_literal: true

module Oms
  # Starts the ship_order BPMN process when an order transitions to "processing".
  # Called from the Order after_commit callback and from the retry UI.
  class StartShipOrder
    def self.call(order)
      key = Busybee::Client.new.start_instance("ship_order", vars: { order: { id: order.id } })
      order.update_column(:ship_order_instance_key, key)
      Rails.logger.info("Started ship_order instance ##{key} for Order ##{order.short_id}")
    rescue StandardError => e
      Rails.logger.error("#{name} failed for Order ##{order.short_id}: #{e.message}")
    end
  end
end
