# frozen_string_literal: true

module Logistics
  class UpdateShipmentStatusWorker < Busybee::Worker
    description "Transitions a shipment to the status specified in the BPMN header"

    variable :shipment_id, type: :uuid, description: "Shipment to transition"
    header   :status,      type: :string, description: "Target shipment status (e.g. packed, in_transit, delivered)"

    output :first_in_transit, type: :boolean, description: "True when this is the first shipment en route"
    output :all_delivered,    type: :boolean, description: "True when every shipment for the order is delivered"

    ALLOWED_STATUSES = %w[packed in_transit delivered].freeze

    def perform
      validate_status!

      { first_in_transit: nil, all_delivered: nil }.tap do |result|
        Shipment.transaction do
          shipment.update!(status: status)

          case status
          when "in_transit" then result[:first_in_transit] = first_in_transit?
          when "delivered" then result[:all_delivered] = all_delivered?
          end
        end

        Rails.logger.info("Shipment ##{shipment.short_id} marked as #{status}")
      end
    end

    private

    def shipment
      @shipment ||= Shipment.find(shipment_id)
    end

    def first_in_transit?
      Shipment.for_order(shipment.order_id).where(status: "in_transit").one?
    end

    def all_delivered?
      Shipment.for_order(shipment.order_id).all? { |s| s.status == "delivered" }
    end

    def validate_status!
      return if ALLOWED_STATUSES.include?(status)

      raise ArgumentError, "Invalid shipment status: #{status.inspect}. Allowed: #{ALLOWED_STATUSES.join(', ')}"
    end
  end
end
