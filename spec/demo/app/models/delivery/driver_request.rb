# frozen_string_literal: true

# == Schema Information
#
# Table name: delivery_driver_requests
#
#  id           :string           not null, primary key
#  shipment_id  :string           not null
#  driver_id    :string
#  requested_at :datetime         not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

module Delivery
  class DriverRequest < Record
    self.table_name = "delivery_driver_requests"

    belongs_to :driver, optional: true

    # shipment_id is a cross-domain reference — no belongs_to association.

    scope :open, -> { where(driver_id: nil).order(:requested_at) }

    before_create do
      self.id ||= SecureRandom.uuid
      self.requested_at ||= Time.current
    end
  end
end
