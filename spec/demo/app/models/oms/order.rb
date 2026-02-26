# frozen_string_literal: true

# == Schema Information
#
# Table name: oms_orders
#
#  id                          :string           not null, primary key
#  customer_name               :string           not null
#  address_line_1              :string
#  city                        :string
#  state                       :string
#  zip                         :string
#  lat                         :decimal(5, 1)    not null
#  lon                         :decimal(5, 1)    not null
#  status                      :string           default("submitted"), not null
#  prepare_order_instance_key  :bigint
#  ship_order_instance_key     :bigint
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#

module Oms
  class Order < ApplicationRecord
    self.table_name = "oms_orders"

    has_many :line_items, class_name: "Oms::LineItem", foreign_key: :order_id, inverse_of: :order, dependent: :destroy

    scope :by_status, ->(status) { where(status: status) }

    after_commit :restock_inventory, on: :create
    after_commit :start_prepare_order, on: :create
    after_commit :start_ship_order, on: :update

    def as_json(*)
      {
        id: id,
        items: line_items.map { |li| { type: li.item_type, qty: li.quantity } },
        address: { lat: lat.to_f, lon: lon.to_f }
      }
    end

    private

    def restock_inventory
      Sim::GuaranteedRestock.call(self)
    end

    # In a real distributed system, process instances would be kicked off by an asynchronous
    # event-driven mechanism. For this demo app, we use ActiveRecord callbacks + service classes:

    def start_prepare_order
      Oms::StartPrepareOrder.call(self)
    end

    def start_ship_order
      return unless saved_change_to_status? && status == "processing"

      Oms::StartShipOrder.call(self)
    end
  end
end
