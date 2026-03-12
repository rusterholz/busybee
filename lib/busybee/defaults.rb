# frozen_string_literal: true

module Busybee
  # Default values for client and worker operations.
  # Can be overridden per-call or via gem configuration.
  module Defaults
    DEFAULT_FAIL_JOB_BACKOFF_MS = 5_000
    DEFAULT_GRPC_RETRY_DELAY_MS = 500
    DEFAULT_JOB_REQUEST_TIMEOUT_MS = 60_000
    DEFAULT_JOB_LOCK_TIMEOUT_MS = 60_000
    DEFAULT_INPUT_REQUIRED = true
    DEFAULT_MAX_JOBS = 25
    DEFAULT_MESSAGE_TTL_MS = 10_000
    DEFAULT_OUTPUT_REQUIRED = true
    DEFAULT_BUFFER_THROTTLE_MS = false
    DEFAULT_BACKPRESSURE_DELAY_MS = 2_000
    DEFAULT_WORKER_MODE = :hybrid
    DEFAULT_STREAMING_BUFFER = true
  end
end
