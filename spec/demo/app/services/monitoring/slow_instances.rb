# frozen_string_literal: true

module Monitoring
  # Process instances whose jobs took longest against their workflow's median
  # instance: per instance, the summed total time of its resolved jobs within
  # the range. Job time only; time an instance spends waiting between jobs
  # never reaches a job hook.
  class SlowInstances
    LIMIT = 10

    SQL = <<~SQL.squish
      WITH per_instance AS (%<per_instance>s),
      medians AS (
        SELECT bpmn_process_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY job_ms) AS median_ms
        FROM per_instance GROUP BY bpmn_process_id
      )
      SELECT per_instance.*, medians.median_ms, per_instance.job_ms / NULLIF(medians.median_ms, 0) AS ratio
      FROM per_instance JOIN medians USING (bpmn_process_id)
      ORDER BY ratio DESC NULLS LAST, job_ms DESC
      LIMIT %<limit>d
    SQL

    def initialize(scope, window)
      @scope = scope.within(window).resolved.where.not(process_instance_key: nil, total_duration_ms: nil)
    end

    # [{ instance_key:, workflow:, jobs:, job_ms:, median_ms:, ratio:, first_at: }], slowest first.
    def rows
      per_instance = @scope.group(:process_instance_key, :bpmn_process_id).
                     select("process_instance_key, bpmn_process_id, COUNT(*) AS jobs, " \
                            "SUM(total_duration_ms) AS job_ms, MIN(activated_at) AS first_at")
      sql = format(SQL, per_instance: per_instance.to_sql, limit: LIMIT)
      JobRun.connection.select_all(sql).map { |row| present(row) }
    end

    private

    def present(row)
      { instance_key: row["process_instance_key"], workflow: row["bpmn_process_id"], jobs: row["jobs"],
        job_ms: row["job_ms"].to_f.round(1), median_ms: row["median_ms"].to_f.round(1),
        ratio: row["ratio"]&.to_f&.round(2), first_at: row["first_at"] }
    end
  end
end
