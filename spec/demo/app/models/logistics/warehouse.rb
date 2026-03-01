# frozen_string_literal: true

# == Schema Information
#
# Table name: logistics_warehouses
#
#  id             :string           not null, primary key
#  name           :string           not null
#  address_line_1 :string
#  city           :string
#  state          :string
#  zip            :string
#  lat            :decimal(5, 1)    not null
#  lon            :decimal(5, 1)    not null
#

module Logistics
  class Warehouse < ApplicationRecord
    self.table_name = "logistics_warehouses"

    has_many :stock_items, class_name: "Logistics::StockItem",
                           foreign_key: :warehouse_id, inverse_of: :warehouse, dependent: :destroy
    has_many :shipments, class_name: "Logistics::Shipment", foreign_key: :warehouse_id, inverse_of: :warehouse

    def as_json(*)
      { id: id, name: name, address: { lat: lat.to_f, lon: lon.to_f } }
    end
  end
end
