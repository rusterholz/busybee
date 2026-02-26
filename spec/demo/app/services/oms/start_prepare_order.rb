# frozen_string_literal: true

module Oms
  # Starts the prepare_order BPMN process for a newly created order.
  # Called from the Order after_commit callback and from the retry UI.
  class StartPrepareOrder
    def self.call(order)
      key = Busybee::Client.new.start_instance("prepare_order", vars: { order: order.as_json })
      order.update_column(:prepare_order_instance_key, key)
      Rails.logger.info("Started prepare_order instance ##{key} for Order ##{order.short_id}")
    rescue StandardError => e
      Rails.logger.error("#{name} failed for Order ##{order.short_id}: #{e.message}")
    end
  end
end
