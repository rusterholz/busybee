# frozen_string_literal: true

require_relative "boot"
require "rails"
require "action_controller/railtie"

# Require gems (including busybee) so Railties are loaded before Rails.application.initialize!
Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.api_only = true

    # Busybee configuration for integration testing
    config.x.busybee.cluster_address = "dummy.zeebe.test:26500"
    config.x.busybee.credential_type = :insecure
    config.x.busybee.worker_name = "dummy-test-worker"
    config.x.busybee.grpc_retry_enabled = true
    config.x.busybee.grpc_retry_delay_ms = 250
    config.x.busybee.default_message_ttl = 30_000
    config.x.busybee.default_fail_job_backoff = 10_000
    config.x.busybee.log_format = :json
  end
end
