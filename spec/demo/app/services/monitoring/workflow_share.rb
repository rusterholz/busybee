# frozen_string_literal: true

module Monitoring
  # How each job type's jobs split across the workflows (bpmn_process_id) they
  # ran in, over the range.
  class WorkflowShare
    def initialize(scope, window)
      @scope = scope.within(window).where.not(bpmn_process_id: nil)
    end

    # [{ job_type:, jobs:, shares: [{ workflow:, jobs:, pct: }] }], busiest type
    # first, each type's workflows largest first.
    def rows
      counts = @scope.group(:job_type, :bpmn_process_id).count
      rows = counts.group_by { |(job_type, _), _| job_type }.map { |job_type, pairs| row(job_type, pairs) }
      rows.sort_by { |row| [-row[:jobs], row[:job_type]] }
    end

    private

    def row(job_type, pairs)
      total = pairs.sum(&:last)
      shares = pairs.map do |(_, workflow), jobs|
        { workflow: workflow, jobs: jobs, pct: (100.0 * jobs / total).round(1) }
      end
      { job_type: job_type, jobs: total, shares: shares.sort_by { |share| [-share[:jobs], share[:workflow]] } }
    end
  end
end
