# frozen_string_literal: true

module Busybee
  module Testing
    # Durations, in milliseconds, the testing helpers use in place of the gem's production defaults:
    # activate_job's wait for a job, the lock on a job the harness activates, a published message's time
    # to correlate, and how long a foreign job sits out: the base times the jobs refused so far, up to the max.
    ACTIVATE_JOB_TIMEOUT_MS = 5_000
    ACTIVATE_JOB_LOCK_MS = 30_000
    PUBLISH_MESSAGE_TTL_MS = 5_000
    FOREIGN_JOB_BACKOFF_MS = 250
    FOREIGN_JOB_MAX_BACKOFF_MS = 2_000
  end
end
