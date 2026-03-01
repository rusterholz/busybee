# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  before_create :assign_uuid

  # Human-friendly display ID from UUID.
  # Returns the last 5 hex characters as "XXX-YY", upcased.
  # Example: UUID "550e8400-e29b-41d4-a716-446655440000" → "400-00"
  def short_id
    hex = id.delete("-").last(5).upcase
    "#{hex[0..2]}-#{hex[3..4]}"
  end

  private

  def assign_uuid
    self.id = SecureRandom.uuid if id.blank?
  end
end
