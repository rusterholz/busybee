# frozen_string_literal: true

module Delivery
  # Abstract base for Delivery models — connects to the delivery database.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :delivery }
  end
end
