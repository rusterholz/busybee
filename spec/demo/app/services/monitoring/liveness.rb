# frozen_string_literal: true

module Monitoring
  # Which workers are up (phase = last lifecycle event, however quiet since),
  # their last engine calls, and how far the recorders' write queues lag.
  class Liveness
    REPORTING_WINDOW = 1.minute

    def initialize(scope = WorkerProcess.all)
      @running = scope.where(status: "running")
      @reporting = @running.where(updated_at: REPORTING_WINDOW.ago..)
    end

    def running_count = @running.count

    # Write-queue depth across the running workers that reported in the last minute.
    def max_queue_depth = @reporting.maximum(:write_queue_depth)
    def mean_queue_depth = @reporting.average(:write_queue_depth)&.to_f

    # { worker_name => time of its latest engine call } for those that have one.
    def last_call_at(worker_names)
      EngineCall.where(worker_name: worker_names).group(:worker_name).maximum(:at)
    end
  end
end
