# frozen_string_literal: true

module Sim
  # Ensures sufficient inventory exists across warehouses to fulfill an order.
  # Called by Oms::Order after_commit before starting the prepare_order BPMN.
  #
  # For each item in the order, tops up every warehouse that stocks it so
  # the planner always has enough inventory to work with.
  class GuaranteedRestock
    def self.call(order)
      order.line_items.each do |li|
        Logistics::StockItem.where(item_type: li.item_type).find_each do |stock|
          stock.update!(quantity: stock.quantity + li.quantity)
        end
      end
    end
  end
end
