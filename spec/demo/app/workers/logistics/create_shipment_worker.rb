# frozen_string_literal: true

module Logistics
  class CreateShipmentWorker < Busybee::Worker
    description "Creates a shipment record and decrements warehouse inventory"

    variable :order_id,     type: :uuid, description: "Order this shipment belongs to"
    variable :warehouse_id, type: :uuid, description: "Warehouse fulfilling this shipment"
    variable :items,        description: "Array of {type, qty} to include in the shipment"

    output :shipment_id, type: :uuid,    description: "Created shipment's ID"
    output :item_count,  type: :integer, description: "Total item count across all line items"

    def perform # rubocop:disable Metrics/AbcSize
      shipment = Shipment.transaction do
        Shipment.create!(
          order_id: order_id,
          warehouse_id: warehouse_id,
          status: "pending",
          items: item_list
        ).tap { decrement_stock!(item_list) }
      end

      warehouse = Warehouse.find(warehouse_id)
      Rails.logger.info("Created Shipment ##{shipment.short_id} from #{warehouse.name} with #{total_count} items")
      { shipment_id: shipment.id, item_count: total_count }
    end

    private

    def item_list
      @item_list ||= items.map { |i| i.transform_keys(&:to_s) }
    end

    def total_count
      item_list.sum { |i| i["qty"] || 1 }
    end

    def decrement_stock!(item_list)
      item_list.each do |item|
        stock = StockItem.find_by!(warehouse_id: warehouse_id, item_type: item["type"])
        stock.update!(quantity: stock.quantity - (item["qty"] || 1))
      end
    end
  end
end
