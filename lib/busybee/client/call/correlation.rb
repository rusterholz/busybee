# frozen_string_literal: true

module Busybee
  class Client
    class Call
      # The call-correlation seam, extended into Call as its class-level surface
      # (Call.with_job / Call.with_worker_status / Call.current_*).
      #
      # The executing Job and the runner's Worker::Status are seeded on the thread
      # so a Call built mid-operation attributes itself (see Call#initialize).
      # Windows are single-carrier — a job window (worker's perform_job) or a
      # worker window (the runner's fetch/lifecycle windows) — so each carrier has
      # its own seeder/reader. Each is restored to its prior value on block exit.
      module Correlation
        # Thread-local keys for the correlation carriers.
        JOB_KEY = :_busybee_call_job
        WORKER_STATUS_KEY = :_busybee_call_worker_status

        def with_job(job)
          previous = Thread.current[JOB_KEY]
          Thread.current[JOB_KEY] = job
          yield
        ensure
          Thread.current[JOB_KEY] = previous
        end

        def with_worker_status(worker_status)
          previous = Thread.current[WORKER_STATUS_KEY]
          Thread.current[WORKER_STATUS_KEY] = worker_status
          yield
        ensure
          Thread.current[WORKER_STATUS_KEY] = previous
        end

        def current_job
          Thread.current[JOB_KEY]
        end

        # Fall-through safety: a present job's own status wins over any separately-
        # seeded one, so a Call's job and worker_status can never disagree.
        def current_worker_status
          job = current_job
          job ? job.worker_status : Thread.current[WORKER_STATUS_KEY]
        end
      end
    end
  end
end
