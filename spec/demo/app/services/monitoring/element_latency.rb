# frozen_string_literal: true

module Monitoring
  # p95 total time per BPMN element of each workflow over the range: which
  # step of a workflow its jobs spend longest in.
  class ElementLatency
    def initialize(scope, window)
      @scope = scope.within(window).resolved.where.not(element_id: nil, total_duration_ms: nil)
    end

    # [{ workflow:, element_id:, job_type:, jobs:, p95_ms: }], slowest first.
    def rows
      keys = %i[bpmn_process_id element_id job_type]
      rows = @scope.group(*keys).pluck(*keys, Arel.sql("COUNT(*)"), Arel.sql(JobRun.percentile_sql(0.95)))
      rows = rows.map do |workflow, element_id, job_type, jobs, p95|
        { workflow: workflow, element_id: element_id, job_type: job_type, jobs: jobs, p95_ms: p95.round(1) }
      end
      rows.sort_by { |row| [-row[:p95_ms], row[:element_id]] }
    end
  end
end
