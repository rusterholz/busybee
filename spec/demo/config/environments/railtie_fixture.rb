# frozen_string_literal: true

# Booted only by the busybee gem's Railtie integration specs
# (spec/integration/rails/railtie_spec.rb), which assert these exact values. Each
# differs from busybee's default, and TLS (not insecure) proves credentials are
# built from config rather than defaulted. Nothing connects to this address.
Rails.application.configure do
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
  config.x.busybee.backpressure_statuses = %i[resource_exhausted unavailable]
end
