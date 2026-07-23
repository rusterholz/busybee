# frozen_string_literal: true

module Monitoring
  # "How live is this page?" — the freshness of the monitoring data itself, for
  # the control-center navbar. Two signals: the recorders' write-queue backlog
  # across running workers (a deep queue means their numbers lag reality), and
  # how long since any worker last wrote a row at all.
  class Liveness
    def initialize(scope = WorkerProcess.all)
      @scope = scope
      @running = scope.where(status: "running")
    end

    def max_queue_depth = @running.maximum(:write_queue_depth)
    def mean_queue_depth = @running.average(:write_queue_depth)&.to_f

    # Seconds since the freshest worker write (nil when there are no workers).
    def freshness_s
      latest = @scope.maximum(:updated_at)
      latest && (Time.current - latest)
    end
  end
end
