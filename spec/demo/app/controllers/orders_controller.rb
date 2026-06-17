# frozen_string_literal: true

class OrdersController < ApplicationController
  def index
    @orders = Oms::Order.includes(:line_items).order(created_at: :desc)
  end

  def show
    @order = Oms::Order.includes(:line_items).find(params[:id])
    @shipments = Logistics::Shipment.where(order_id: @order.id).includes(:warehouse)
  end

  def new
    @item_catalog = Rails.application.config.x.demo.item_catalog
    @defaults = {
      customer_name: Faker::Name.name,
      address_line_1: Faker::Address.street_address,
      city: Faker::Address.city,
      state: Faker::Address.state_abbr,
      zip: Faker::Address.zip_code,
      lat: rand(-90..90) / 10.0,
      lon: rand(-90..90) / 10.0
    }
  end

  def create
    order = nil
    Oms::Record.transaction do
      order = Oms::Order.create!(order_params)
      build_line_items(order)
    end
    redirect_to order_path(order), notice: "Order #{order.short_id} created."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to new_order_path, alert: e.message
  end

  def start_prepare_order
    order = Oms::Order.find(params[:id])
    Oms::StartPrepareOrder.call(order)
    redirect_to order_path(order), notice: "Starting prepare_order process..."
  end

  def start_ship_order
    order = Oms::Order.find(params[:id])
    Oms::StartShipOrder.call(order)
    redirect_to order_path(order), notice: "Starting ship_order process..."
  end

  private

  def order_params
    params.require(:order).permit(:customer_name, :address_line_1, :city, :state, :zip, :lat, :lon)
  end

  def build_line_items(order)
    items = params[:items] || {}
    items.each do |item_type, attrs|
      qty = attrs[:qty].to_i
      next unless qty.positive?

      Oms::LineItem.create!(order: order, item_type: item_type, quantity: qty)
    end
  end
end
