# frozen_string_literal: true

module Monitoring
  # One row per job type over the range: volume, timing and failure rate, the
  # Workers page's comparison across types.
  class JobTypeSummary
    def initialize(scope, window)
      @scope = scope.within(window)
      @window = window
    end

    # [{ job_type:, jobs:, per_minute:, p50_ms:, p95_ms:, failure_pct:, error_pct: }], busiest first.
    def rows
      jobs = @scope.group(:job_type).count
      timings = @scope.resolved.group(:job_type).pluck(:job_type, *aggregates).index_by(&:first)
      rows = jobs.map { |job_type, count| row(job_type, count, timings[job_type]) }
      rows.sort_by { |row| [-row[:jobs], row[:job_type]] }
    end

    private

    def aggregates
      [JobRun.percentile_sql(0.5), JobRun.percentile_sql(0.95),
       JobRun.share_sql("failed"), JobRun.share_sql("error")].map { |sql| Arel.sql(sql) }
    end

    def row(job_type, count, timing)
      _, p50, p95, failed, errored = timing
      { job_type: job_type, jobs: count, per_minute: (count / @window.minutes).round(2),
        p50_ms: p50&.round(1), p95_ms: p95&.round(1),
        failure_pct: failed&.to_f&.round(1), error_pct: errored&.to_f&.round(1) }
    end
  end
end
