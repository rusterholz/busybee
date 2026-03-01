# frozen_string_literal: true

module Logistics
  class MarkShipmentPackedWorker < Busybee::Worker
    description "Transitions a shipment to packed, triggering the deliver_shipment process"

    variable :shipment_id, type: :uuid, description: "Shipment to mark as packed"

    def perform
      shipment = Shipment.find(shipment_id)
      shipment.update!(status: "packed")
      Rails.logger.info("Shipment ##{shipment.short_id} marked as packed")
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
