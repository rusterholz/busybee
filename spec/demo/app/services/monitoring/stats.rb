# frozen_string_literal: true

module Monitoring
  # Status counts for a (possibly filtered) set of job runs: the Workers page's tiles.
  class Stats
    STATUSES = %w[ready complete failed error handed_back].freeze

    def initialize(scope)
      @scope = scope
    end

    def total_count = @scope.count

    def counts_by_status
      counts = @scope.group(:status).count
      STATUSES.index_with { |status| counts.fetch(status, 0) }
    end
  end
end
