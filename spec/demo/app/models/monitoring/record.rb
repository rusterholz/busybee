# frozen_string_literal: true

module Monitoring
  # Abstract base for Monitoring models — connects to the monitoring database,
  # so the observability sink never contends with business writes.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :monitoring }
  end
end
