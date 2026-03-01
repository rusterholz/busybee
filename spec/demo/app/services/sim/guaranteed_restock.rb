# frozen_string_literal: true

module Sim
  # Ensures sufficient inventory exists across warehouses to fulfill an order.
  # Called by Oms::Order after_commit before starting the prepare_order BPMN.
  #
  # Creates a sawtooth restocking pattern: when any warehouse runs low on an
  # item, restock it generously (q+1); when all warehouses have plenty, add a
  # partial restock (2q/3) so stock gradually declines until the next spike.
  class GuaranteedRestock
    def self.call(order)
      order.line_items.each { |li| restock_item(li.item_type, li.quantity) }
    end

    def self.restock_item(item_type, qty)
      stocks = Logistics::StockItem.where(item_type: item_type).to_a
      return if stocks.empty?

      low = stocks.select { |s| s.quantity < qty }
      depleted = low.any?
      target = depleted ? low.sample : stocks.sample
      amount = depleted ? qty + 1 : (qty * 2.0 / 3).ceil
      target.update!(quantity: target.quantity + amount)
    end
    private_class_method :restock_item
  end
end
