# frozen_string_literal: true

module Monitoring
  # Rollups over the raw engine-call rows for the control center: counts and
  # exact network-time stats, grouped by rpc and by the worker class that made
  # the call.
  class CallStats
    AGGREGATES = [Arel.sql("COUNT(*)"), Arel.sql("AVG(network_ms)"),
                  Arel.sql("MIN(network_ms)"), Arel.sql("MAX(network_ms)")].freeze

    def initialize(scope = EngineCall.all)
      @scope = scope
    end

    def total_calls = @scope.count

    def calls_per_job(job_count)
      return 0.0 if job_count.zero?

      total_calls.to_f / job_count
    end

    # [{ rpc:, count:, mean_ms:, min_ms:, max_ms: }], busiest first.
    def by_rpc = summarize(@scope.group(:rpc).pluck(:rpc, *AGGREGATES))

    # [{ worker_class:, count:, rpcs: [<by_rpc rows>] }], busiest first — the
    # calls-by-rpc view grouped by the worker that made them.
    def by_worker
      rows = @scope.group(:worker_class, :rpc).pluck(:worker_class, :rpc, *AGGREGATES)
      workers = rows.group_by(&:first).map do |worker_class, group|
        rpcs = summarize(group.map { |row| row.drop(1) })
        { worker_class: worker_class, count: rpcs.sum { |rpc| rpc[:count] }, rpcs: rpcs }
      end
      workers.sort_by { |worker| [-worker[:count], worker[:worker_class].to_s] }
    end

    private

    def summarize(rows)
      summaries = rows.map do |rpc, count, mean, min, max|
        { rpc: rpc, count: count, mean_ms: mean&.to_f, min_ms: min, max_ms: max }
      end
      summaries.sort_by { |row| [-row[:count], row[:rpc].to_s] }
    end
  end
end
