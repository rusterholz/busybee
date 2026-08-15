# frozen_string_literal: true

module Busybee
  module Testing
    # Durations the harness owns. Users should not need to remember to override
    # their production timing defaults in test, so the testing module owns its
    # own set of default values.
    #
    # Each is named for the helper that reads it, deliberately unlike the
    # Busybee::Defaults constant it would otherwise be confused with. Every one
    # is overridable per call, and every call site accepts what the rest of the
    # gem accepts: a number of milliseconds or an ActiveSupport::Duration.

    # How long activate_job / activate_jobs wait for a job to appear. Either a
    # job is expected, and the engine produces it in well under a second, or it
    # is expected to be absent and the spec wants to learn that promptly. A
    # production long-poll serves neither.
    ACTIVATE_JOB_TIMEOUT_MS = 5_000

    # How long the engine leaves a job activated for the spec that took it.
    # Shorter than a worker's lock: an example that dies mid-flight should hand
    # the job back before the next one runs, not a minute later.
    ACTIVATE_JOB_LOCK_MS = 30_000

    # How long a message published by the harness waits to correlate. A spec's
    # correlation either happens in the next few lines or has already failed.
    PUBLISH_MESSAGE_TTL_MS = 5_000
  end
end
