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

        # Use Rails logger by default in Rails apps
        config.logger = Rails.logger
        config.cluster_address = busybee_conf&.cluster_address.presence

        # Credentials configuration
        config.credential_type = busybee_conf&.credential_type.presence if busybee_conf&.credential_type.presence
        config.credentials = busybee_conf&.credentials if busybee_conf&.credentials

        # GRPC retry configuration
        config.grpc_retry_enabled = !!busybee_conf.grpc_retry_enabled unless busybee_conf&.grpc_retry_enabled.nil?
        config.grpc_retry_delay_ms = busybee_conf.grpc_retry_delay_ms.to_i if busybee_conf&.grpc_retry_delay_ms.presence

        if busybee_conf&.grpc_retry_errors.presence
          config.grpc_retry_errors = Array(busybee_conf.grpc_retry_errors.presence)
        end
      end
    end
  end
end
