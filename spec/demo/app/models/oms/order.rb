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

    after_commit :on_create_start_prepare_order, on: :create
    after_commit :on_processing_start_ship_order, on: :update

    def as_json(*)
      {
        id: id,
        items: line_items.map { |li| { type: li.item_type, qty: li.quantity } },
        address: { lat: lat.to_f, lon: lon.to_f }
      }
    end

    private

    # In a real distributed system, the process instances should be kicked off by some other
    # asynchronous event-driven mechanism. For this demo app, we just use ActiveRecord callbacks:

    def on_create_start_prepare_order
      Sim::GuaranteedRestock.call(self)

      # TODO: Use busybee async mode when available. Production apps need error handling here.
      key = Busybee::Client.new.start_instance("prepare_order", vars: { order: as_json })
      update_column(:prepare_order_instance_key, key)
    end

    def on_processing_start_ship_order
      return unless saved_change_to_status? && status == "processing"

      # TODO: Use busybee async mode when available. Production apps need error handling here.
      key = Busybee::Client.new.start_instance("ship_order", vars: { order: as_json.slice(:id) })
      update_column(:ship_order_instance_key, key)
    end
  end
end
