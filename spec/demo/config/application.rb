# frozen_string_literal: true

require_relative "boot"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "active_record/railtie"

# Require gems (including busybee) so Railties are loaded before Rails.application.initialize!
Bundler.require(*Rails.groups)

module Demo
  # Per-boot worker identity for the running demo stack (wired in development.rb;
  # application.rb keeps a fixed name for the test env). The random suffix makes
  # each container boot a distinct incarnation in the monitoring control center;
  # DEMO_DOMAIN, when set per service, prefixes it for legibility — the
  # (worker_name, job_type) key already isolates domains without it.
  def self.worker_name(domain: ENV.fetch("DEMO_DOMAIN", nil), random: SecureRandom.alphanumeric(5))
    prefix = domain.present? ? "#{domain}-" : ""
    "#{prefix}worker-#{random}"
  end

  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false

    # Autoload paths for namespaced models and services
    config.autoload_paths += %W[
      #{root}/app/models
      #{root}/app/services
      #{root}/app/workers
    ]

    # Busybee configuration for integration testing
    # Use TLS (not insecure) to prove credentials are built from config, not defaulted
    config.x.busybee.cluster_address = "dummy.zeebe.test:443"
    config.x.busybee.credential_type = :tls
    config.x.busybee.worker_name = "dummy-test-worker"
    config.x.busybee.grpc_retry_enabled = true
    config.x.busybee.grpc_retry_delay = 250
    config.x.busybee.default_message_ttl = 30_000
    config.x.busybee.default_fail_job_backoff = 10_000
    config.x.busybee.default_polling_request_timeout = 30_000
    config.x.busybee.default_job_timeout = 120_000
    config.x.busybee.log_format = :json
  end
end
