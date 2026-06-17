# frozen_string_literal: true

module Logistics
  # Abstract base for Logistics models — connects to the logistics database.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :logistics }
  end
end
