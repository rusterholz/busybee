# frozen_string_literal: true

module Logistics
  class LoadItemAvailabilityWorker < Busybee::Worker
    description "Checks which warehouses have a given item type in stock"

    variable :item_type, type: :string, description: "Item type to check availability for"

    output :warehouse_ids, description: "IDs of warehouses with quantity > 0"

    def perform
      ids = StockItem.where(item_type: item_type).where("quantity > 0").pluck(:warehouse_id)
      Rails.logger.info("#{item_type} available at #{ids.size} warehouse(s)")
      { warehouse_ids: ids }
    end
  end
end
