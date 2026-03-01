# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    @order_counts = Oms::Order.group(:status).count
    @total_orders = @order_counts.values.sum

    @active_shipments = Logistics::Shipment.where.not(status: "delivered").count
    @total_shipments = Logistics::Shipment.count

    @available_drivers = Delivery::Driver.available.count
    @total_drivers = Delivery::Driver.count
  end
end
