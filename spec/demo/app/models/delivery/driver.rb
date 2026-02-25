# frozen_string_literal: true

# == Schema Information
#
# Table name: delivery_drivers
#
#  id                  :string           not null, primary key
#  name                :string           not null
#  current_shipment_id :string
#  total_mileage       :decimal(8, 2)    default(0.0), not null
#

module Delivery
  class Driver < ApplicationRecord
    self.table_name = "delivery_drivers"

    # current_shipment_id is a cross-domain reference — no belongs_to association.

    scope :available, -> { where(current_shipment_id: nil) }
    scope :by_mileage, -> { order(:total_mileage) }
  end
end
