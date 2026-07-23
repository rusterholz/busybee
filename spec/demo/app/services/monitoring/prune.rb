# frozen_string_literal: true

module Monitoring
  # Retention sweep for the monitoring window, run periodically by clockwork.
  # Drops worker incarnations nothing has touched past the horizon — live rows
  # refresh continuously via the worker hooks and call stream, so an untouched
  # row is a dead one — plus job runs stuck "ready" that long (their resolution
  # died with the process that owed it). Resolved run history is kept.
  class Prune
    HORIZON = 10.minutes

    def self.run(now: Time.current)
      cutoff = now - HORIZON
      { workers: WorkerProcess.where(updated_at: ...cutoff).delete_all,
        runs: JobRun.where(status: "ready").where(updated_at: ...cutoff).delete_all }
    end
  end
end
