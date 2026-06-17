# frozen_string_literal: true

# == Schema Information
#
# Table name: logistics_stock_items
#
#  id           :string           not null, primary key
#  warehouse_id :string           not null
#  item_type    :string           not null
#  quantity     :integer          default(0), not null
#
# Indexes
#
#  index_logistics_stock_items_on_warehouse_id               (warehouse_id)
#  index_logistics_stock_items_on_warehouse_id_and_item_type (warehouse_id, item_type) UNIQUE
#

module Logistics
  class StockItem < Record
    self.table_name = "logistics_stock_items"

    belongs_to :warehouse, class_name: "Logistics::Warehouse", inverse_of: :stock_items
  end
end
