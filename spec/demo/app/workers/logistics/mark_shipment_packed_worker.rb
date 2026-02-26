# frozen_string_literal: true

module Logistics
  class MarkShipmentPackedWorker < Busybee::Worker
    description "Transitions a shipment to packed, triggering the deliver_shipment process"

    variable :shipment_id, type: :uuid, description: "Shipment to mark as packed"

    def perform
      Shipment.transaction do
        Shipment.find(shipment_id).update!(status: "packed")
      end
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
