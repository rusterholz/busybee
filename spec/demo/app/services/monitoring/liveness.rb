# frozen_string_literal: true

module Monitoring
  # Which workers are up (phase = last lifecycle event, however quiet since),
  # their last engine calls, and how far the recorders' write queues lag.
  class Liveness
    def initialize(scope = WorkerProcess.all)
      @running = scope.where(status: "running")
    end

    def running_count = @running.count
    def max_queue_depth = @running.maximum(:write_queue_depth)
    def mean_queue_depth = @running.average(:write_queue_depth)&.to_f

    # { worker_name => time of its latest engine call } for those that have one.
    def last_call_at(worker_names)
      EngineCall.where(worker_name: worker_names).group(:worker_name).maximum(:at)
    end
  end
end
