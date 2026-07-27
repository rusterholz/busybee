# frozen_string_literal: true

module Sim
  # Raised to recycle a business worker — the demo's stand-in for a k8s rollout
  # SIGTERM-ing a pod. Declared a shutdown error (config/initializers/busybee.rb),
  # so raising it during perform shuts the worker down gracefully (reason
  # :unhealthy); `restart: unless-stopped` then brings the container back as a
  # fresh incarnation. See Sim::RolloverPolicy for when it fires.
  Rollover = Class.new(StandardError)
end
