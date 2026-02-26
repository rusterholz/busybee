# frozen_string_literal: true

class ShipmentsController < ApplicationController
  def start_deliver_shipment
    shipment = Logistics::Shipment.find(params[:id])
    Logistics::StartDeliverShipment.call(shipment)
    redirect_to order_path(shipment.order_id), notice: "Starting deliver_shipment process..."
  end
end
