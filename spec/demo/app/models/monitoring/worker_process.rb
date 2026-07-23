# frozen_string_literal: true

module Monitoring
  # One row per worker incarnation, keyed by (worker_name, job_type) — worker_name
  # is unique per container boot, so each boot is a fresh incarnation and a rolled
  # worker leaves its predecessor visible. Upserted by the busybee worker
  # lifecycle hooks as the worker moves running → stop_requested → stopping →
  # shutdown, carrying its counters, buffer gauges, timing, and stop reason.
  class WorkerProcess < Record
    self.table_name = "monitoring_worker_processes"

    scope :recent, -> { order(started_at: :desc) }
  end
end
