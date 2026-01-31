# frozen_string_literal: true

require "rails"
require "active_support/core_ext/object/blank"
require "busybee"

module Busybee
  # Rails integration for Busybee.
  # Automatically configures Busybee from Rails configuration.
  #
  # @example config/application.rb or config/environments/*.rb
  #   config.x.busybee.cluster_address = "cluster.zeebe.camunda.io:443"
  #   config.x.busybee.credential_type = "oauth"  # or "insecure"
  #   config.x.busybee.credentials = MyCustomCredentials.new(...)  # optional explicit override
  #
  class Railtie < Rails::Railtie
    initializer "busybee.configure" do
      Busybee.configure do |config|
        busybee_conf = Rails.configuration.x.busybee.presence

        # Logger: Rails.logger by default, custom logger if set, nil if explicitly false
        config.logger = case busybee_conf&.logger
                        when false then nil
                        when nil, true then Rails.logger
                        else busybee_conf.logger
                        end

        config.log_format = busybee_conf&.log_format.presence if busybee_conf&.log_format.presence
        config.cluster_address = busybee_conf&.cluster_address.presence
        config.worker_name = busybee_conf&.worker_name.presence

        # Credentials configuration
        config.credential_type = busybee_conf&.credential_type.presence if busybee_conf&.credential_type.presence
        config.credentials = busybee_conf&.credentials if busybee_conf&.credentials.is_a?(Busybee::Credentials)

        # GRPC retry configuration
        config.grpc_retry_enabled = !!busybee_conf.grpc_retry_enabled unless busybee_conf&.grpc_retry_enabled.nil?
        config.grpc_retry_delay_ms = busybee_conf.grpc_retry_delay_ms.to_i if busybee_conf&.grpc_retry_delay_ms.presence

        if busybee_conf&.grpc_retry_errors.presence
          config.grpc_retry_errors = Array(busybee_conf.grpc_retry_errors.presence)
        end

        # Client API method defaults
        config.default_message_ttl = busybee_conf.default_message_ttl if busybee_conf&.default_message_ttl.presence

        if busybee_conf&.default_fail_job_backoff.presence
          config.default_fail_job_backoff = busybee_conf.default_fail_job_backoff
        end
      end
    end
  end
end
