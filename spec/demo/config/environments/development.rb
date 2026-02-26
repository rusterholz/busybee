# frozen_string_literal: true

Rails.application.configure do
  # Override busybee config for local Zeebe (application.rb has dummy values for Railtie tests)
  config.x.busybee.cluster_address = ENV.fetch("CLUSTER_ADDRESS", "localhost:26500")
  config.x.busybee.credential_type = :insecure

  # Log to STDOUT so Docker container logs capture worker output
  if ENV["RAILS_LOG_TO_STDOUT"].present?
    $stdout.sync = true
    config.logger = ActiveSupport::Logger.new($stdout)
    config.logger.formatter = config.log_formatter
    config.log_level = :info
  end
end
