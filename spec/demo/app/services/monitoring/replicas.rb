# frozen_string_literal: true

module Monitoring
  # Replicas per job type over time, from worker lifecycle intervals: at instant
  # t, the incarnations started at or before t and not shut down by t. An
  # incarnation killed before its shutdown hooks never records a shutdown, so it
  # keeps counting until the worker-table sweep deletes it.
  class Replicas
    SERIES_SQL = <<~SQL.squish
      SELECT instants.t, workers.job_type, COUNT(*) FILTER (WHERE workers.started_at <= instants.t
        AND (workers.shutdown_at IS NULL OR workers.shutdown_at > instants.t))
      FROM generate_series(:from::timestamp, :to::timestamp, :step::interval) AS instants(t)
      CROSS JOIN monitoring_worker_processes workers
      WHERE workers.started_at IS NOT NULL
      GROUP BY instants.t, workers.job_type
    SQL

    def initialize(from:, to:, step:)
      @from = from.utc
      @to = to.utc
      @step = step
    end

    # { job_type => { instant => count } }, every instant present for every type.
    def series
      series = Hash.new { |hash, job_type| hash[job_type] = {} }
      rows.each { |instant, job_type, count| series[job_type][utc(instant)] = count.to_i }
      series.transform_values { |counts| counts.sort.to_h }.sort.to_h
    end

    private

    def rows
      sql = WorkerProcess.sanitize_sql([SERIES_SQL, { from: @from, to: @to, step: "#{@step.to_i} seconds" }])
      WorkerProcess.connection.select_rows(sql)
    end

    def utc(instant) = Time.find_zone("UTC").parse(instant.to_s)
  end
end
