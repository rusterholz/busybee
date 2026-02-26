# frozen_string_literal: true

class WarehousesController < ApplicationController
  def index
    @warehouses = Logistics::Warehouse.includes(:stock_items).all
  end

  def show
    @warehouse = Logistics::Warehouse.includes(:stock_items, :shipments).find(params[:id])
    @shipments = @warehouse.shipments.order(created_at: :desc).limit(20)
  end
end
