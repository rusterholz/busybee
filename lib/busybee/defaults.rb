# frozen_string_literal: true

module Busybee
  # Default values for client and worker operations.
  # Can be overridden per-call or via gem configuration.
  module Defaults
    DEFAULT_FAIL_JOB_BACKOFF_MS = 5_000
    DEFAULT_JOB_TIMEOUT_MS = 60_000
    DEFAULT_MAX_JOBS = 25
    DEFAULT_MESSAGE_TTL_MS = 10_000
    DEFAULT_REQUEST_TIMEOUT_MS = 60_000
  end
end
