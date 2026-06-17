# frozen_string_literal: true

module Oms
  # Abstract base for OMS models — connects to the oms database.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :oms }
  end
end
