# frozen_string_literal: true

module Monitoring
  # Job runs over time, bucketed by activation: the Workers page's charts. Each
  # method returns Chartkick-ready series ({ name => { bucket => value } }).
  class JobTrends
    def initialize(scope, window)
      @scope = scope.within(window)
      @window = window
      @bucket = Arel.sql(window.bucket_sql(:activated_at))
    end

    # Resolved jobs per minute by outcome, zero in quiet buckets.
    def throughput
      counts = @scope.where(status: JobRun::OUTCOMES).group(@bucket, :status).count
      JobRun::OUTCOMES.index_with do |status|
        @window.buckets.index_with { |at| @window.per_minute(counts.fetch([at, status], 0)) }
      end
    end

    # p50 and p95 total time per bucket over resolved runs.
    def latency
      rows = @scope.resolved.where.not(total_duration_ms: nil).group(@bucket).
             pluck(@bucket, Arel.sql(JobRun.percentile_sql(0.5)), Arel.sql(JobRun.percentile_sql(0.95)))
      { "p50" => rows.to_h { |at, p50, _| [at, p50.round(1)] }, "p95" => rows.to_h { |at, _, p95| [at, p95.round(1)] } }
    end

    # Percent of resolved runs that failed, per bucket with any resolved run.
    def failure_rate
      @scope.resolved.group(@bucket).pluck(@bucket, Arel.sql(JobRun.share_sql("failed"))).
        to_h { |at, pct| [at, pct.to_f.round(1)] }
    end
  end
end
