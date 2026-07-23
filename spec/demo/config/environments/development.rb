# frozen_string_literal: true

Rails.application.configure do
  # Override busybee config for local Zeebe (application.rb has dummy values for Railtie tests)
  config.x.busybee.cluster_address = ENV.fetch("CLUSTER_ADDRESS", "localhost:26500")
  config.x.busybee.credential_type = :insecure

  # Per-boot worker identity so each container boot is a distinct incarnation in
  # the monitoring control center (application.rb keeps the fixed test-env name).
  config.x.busybee.worker_name = Demo.worker_name

  # Log to STDOUT so Docker container logs capture worker output
  if ENV["RAILS_LOG_TO_STDOUT"].present?
    $stdout.sync = true
    config.logger = ActiveSupport::Logger.new($stdout)
    # Stamp every line with a UTC time so container logs read on a timeline —
    # busybee's JSON payloads and the sim's rollover notices alike.
    config.logger.formatter = proc do |severity, time, _progname, msg|
      "#{time.utc.iso8601(3)} #{severity.ljust(5)} #{msg}\n"
    end
    config.log_level = :info
  end
end
