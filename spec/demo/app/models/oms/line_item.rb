# frozen_string_literal: true

# == Schema Information
#
# Table name: oms_line_items
#
#  id        :string           not null, primary key
#  order_id  :string           not null
#  item_type :string           not null
#  quantity  :integer          default(1), not null
#
# Indexes
#
#  index_oms_line_items_on_order_id  (order_id)
#

module Oms
  class LineItem < ApplicationRecord
    self.table_name = "oms_line_items"

    belongs_to :order, class_name: "Oms::Order", inverse_of: :line_items
  end
end
