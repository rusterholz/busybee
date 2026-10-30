# frozen_string_literal: true

module Busybee
  module Testing
    # Durations, in milliseconds, the testing helpers use in place of the gem's production defaults:
    # activate_job's wait for a job, the lock on a job the harness activates, a published message's
    # time to correlate, and how long a job handed back as foreign stays out of activation's reach.
    ACTIVATE_JOB_TIMEOUT_MS = 5_000
    ACTIVATE_JOB_LOCK_MS = 30_000
    PUBLISH_MESSAGE_TTL_MS = 5_000
    FOREIGN_JOB_BACKOFF_MS = 250
  end
end
