# frozen_string_literal: true

module Monitoring
  # Aggregate numbers for a (possibly filtered) set of job runs, shown at the top
  # of the Monitoring dashboard. Duration stats are computed over resolved rows
  # only — async workers record perform ~0 at dispatch, so including their
  # unresolved rows would drag the timing means toward zero. The status counts
  # still include them, so that work stays visible.
  class Stats
    STATUSES = %w[ready complete failed error].freeze

    def initialize(scope)
      @scope = scope
      @resolved = scope.where.not(status: "ready")
    end

    def total_count
      @scope.count
    end

    def counts_by_status
      counts = @scope.group(:status).count
      STATUSES.index_with { |status| counts.fetch(status, 0) }
    end

    def mean_total_ms = @resolved.average(:total_duration_ms)
    def max_total_ms = @resolved.maximum(:total_duration_ms)
    def mean_perform_ms = @resolved.average(:perform_duration_ms)
    def max_perform_ms = @resolved.maximum(:perform_duration_ms)
    def mean_buffer_ms = @resolved.average(:buffer_latency_ms)
    def max_buffer_ms = @resolved.maximum(:buffer_latency_ms)

    # Instantaneous gauge rather than a time-average: the deepest buffer seen
    # across the current selection (max across job types when several are shown).
    def max_buffer_depth = @scope.maximum(:buffer_size)

    # How many runs arrived buffered (activated onto the stream while a job was
    # already in flight) — hybrid mode's stream/poll split made visible.
    def buffered_count = @scope.where(buffered: true).count

    # Per-job-type rollup for the contract view: [{ job_type:, total:, complete:,
    # failed:, error:, mean_total_ms: }], busiest first. Means over resolved rows
    # only (same async-dispatch caveat as the scalar timings above).
    def by_job_type
      by_status = @scope.group(:job_type, :status).count
      means = @resolved.group(:job_type).average(:total_duration_ms)
      rows = @scope.group(:job_type).count.map { |job_type, total| job_type_row(job_type, total, by_status, means) }
      rows.sort_by { |row| [-row[:total], row[:job_type].to_s] }
    end

    private

    def job_type_row(job_type, total, by_status, means)
      { job_type: job_type, total: total,
        complete: by_status.fetch([job_type, "complete"], 0),
        failed: by_status.fetch([job_type, "failed"], 0),
        error: by_status.fetch([job_type, "error"], 0),
        mean_total_ms: means[job_type]&.to_f }
    end
  end
end
