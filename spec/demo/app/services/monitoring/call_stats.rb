# frozen_string_literal: true

module Monitoring
  # Rollups over the engine_call aggregate for the control center. CallMetric
  # keys each row by the full context_tags tuple, so a single rpc (or worker)
  # spans several rows; these methods re-group those rows for display. Durations
  # combine as a count-weighted mean of the per-tuple EWMAs — a fair "typical
  # latency", not an exact recomputation (the raw samples are long gone).
  class CallStats
    def initialize(scope = CallMetric.where(metric_name: "engine_call"))
      @rows = scope.to_a
    end

    def total_calls = @rows.sum(&:count)

    def calls_per_job(job_count)
      return 0.0 if job_count.zero?

      total_calls.to_f / job_count
    end

    # [{ rpc:, count:, mean_ms:, min_ms:, max_ms: }], busiest first.
    def by_rpc = summarize(@rows, :rpc, "rpc")

    # [{ worker_class:, count:, rpcs: [<by_rpc rows>] }], busiest first — the
    # calls-by-rpc view grouped by the worker that made them.
    def by_worker
      workers = grouped(@rows, "worker_class").map do |worker_class, rows|
        { worker_class: worker_class, count: rows.sum(&:count), rpcs: summarize(rows, :rpc, "rpc") }
      end
      workers.sort_by { |worker| [-worker[:count], worker[:worker_class].to_s] }
    end

    private

    def summarize(rows, label, tag)
      summaries = grouped(rows, tag).map do |value, group|
        count = group.sum(&:count)
        { label => value, count: count, mean_ms: weighted_mean(group, count),
          min_ms: group.filter_map(&:minimum).min, max_ms: group.filter_map(&:maximum).max }
      end
      summaries.sort_by { |row| [-row[:count], row[label].to_s] }
    end

    def grouped(rows, tag) = rows.group_by { |row| row.tags[tag] }

    def weighted_mean(rows, count)
      return nil if count.zero?

      rows.sum { |row| (row.ewma || 0.0) * row.count } / count
    end
  end
end
