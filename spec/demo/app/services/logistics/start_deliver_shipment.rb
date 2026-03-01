# frozen_string_literal: true

module Logistics
  # Starts the deliver_shipment BPMN process when a shipment becomes "packed".
  # Called from the Shipment after_commit callback and from the retry UI.
  class StartDeliverShipment
    def self.call(shipment)
      key = Busybee::Client.new.start_instance(
        "deliver_shipment",
        vars: { shipment: shipment.as_json.except(:item_count) }
      )
      shipment.update_column(:deliver_shipment_instance_key, key)
      Rails.logger.info("Started deliver_shipment instance ##{key} for Shipment ##{shipment.short_id}")
    rescue StandardError => e
      Rails.logger.error("#{name} failed for Shipment ##{shipment.short_id}: #{e.message}")
    end
  end
end
