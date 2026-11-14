# frozen_string_literal: true

module Monitoring
  # Network time of the calls workers make to the gateway, per rpc, over the
  # range. The fetch RPCs are left out: their time is a wait for work.
  class NetworkStats
    def initialize(scope, window)
      @scope = scope.within(window).where.not(rpc: EngineCall::LONG_POLLS).where.not(network_ms: nil)
      @window = window
    end

    # [{ rpc:, calls:, p50_ms:, p95_ms:, retried:, max_attempts:, backoff_ms: }], busiest first.
    COLUMNS = %i[rpc calls p50_ms p95_ms retried max_attempts backoff_ms].freeze

    def rows
      rows = @scope.group(:rpc).pluck(:rpc, *aggregates).map do |values|
        COLUMNS.zip(values).to_h { |key, value| [key, key.end_with?("_ms") ? value&.round(1) : value] }
      end
      rows.sort_by { |row| [-row[:calls], row[:rpc]] }
    end

    # { rpc => { bucket => p95 } }, every bucket present, nil where the rpc made no call.
    def p95_series
      bucket = Arel.sql(@window.bucket_sql(:at))
      values = @scope.group(:rpc, bucket).pluck(:rpc, bucket, Arel.sql(EngineCall.percentile_sql(0.95, :network_ms)))
      values.group_by(&:first).sort.to_h do |rpc, rows|
        by_bucket = rows.to_h { |_, at, p95| [at, p95.round(1)] }
        [rpc, @window.buckets.index_with { |at| by_bucket[at] }]
      end
    end

    private

    def aggregates
      ["COUNT(*)", EngineCall.percentile_sql(0.5, :network_ms), EngineCall.percentile_sql(0.95, :network_ms),
       "COUNT(*) FILTER (WHERE attempts > 1)", "MAX(attempts)", "SUM(backoff_ms)"].map { |sql| Arel.sql(sql) }
    end
  end
end
