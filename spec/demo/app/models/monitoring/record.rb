# frozen_string_literal: true

module Monitoring
  # Abstract base for Monitoring models: connects to the monitoring database,
  # so the observability sink never contends with business writes.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: { writing: :monitoring }

    # Exact percentile of a column, as a SELECT expression.
    def self.percentile_sql(fraction, column)
      "percentile_cont(#{Float(fraction)}) WITHIN GROUP (ORDER BY #{connection.quote_column_name(column)})"
    end
  end
end
