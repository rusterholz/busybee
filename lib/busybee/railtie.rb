# frozen_string_literal: true

require "rails"
require "active_support/core_ext/object/blank"
require "busybee"

module Busybee
  # Rails integration for Busybee.
  # Automatically configures Busybee from Rails configuration.
  #
  # @example Basic configuration
  #   config.x.busybee.cluster_address = "localhost:26500"
  #   config.x.busybee.credential_type = :insecure
  #
  # @example Camunda Cloud with Rails credentials
  #   config.x.busybee.credential_type = :camunda_cloud
  #   config.x.busybee.client_id = Rails.application.credentials.zeebe[:client_id]
  #   config.x.busybee.client_secret = Rails.application.credentials.zeebe[:client_secret]
  #   config.x.busybee.cluster_id = Rails.application.credentials.zeebe[:cluster_id]
  #   config.x.busybee.region = "bru-2"
  #
  # @example Explicit credentials object
  #   config.x.busybee.credentials = MyCustomCredentials.new(...)
  #
  class Railtie < Rails::Railtie
    # Credential parameters that can be configured via config.x.busybee.*
    CREDENTIAL_PARAMS = %i[
      cluster_address client_id client_secret cluster_id region
      token_url audience scope certificate_file
    ].freeze

    initializer "busybee.configure" do
      Busybee.configure do |config|
        busybee_conf = Rails.configuration.x.busybee

        # Logger: Rails.logger by default, custom logger if set, nil if explicitly false
        config.logger = case busybee_conf&.logger
                        when false then nil
                        when nil, true then Rails.logger
                        else busybee_conf.logger
                        end

        next unless busybee_conf.presence

        config.log_format = busybee_conf.log_format.presence if busybee_conf.log_format.presence
        config.cluster_address = busybee_conf.cluster_address.presence
        config.worker_name = busybee_conf.worker_name.presence

        # Credentials: explicit object, or build from type + params
        Busybee::Railtie.configure_credentials(config, busybee_conf)

        # GRPC retry configuration
        config.grpc_retry_enabled = !!busybee_conf.grpc_retry_enabled unless busybee_conf.grpc_retry_enabled.nil?
        config.grpc_retry_delay_ms = busybee_conf.grpc_retry_delay_ms if busybee_conf.grpc_retry_delay_ms.presence
        config.grpc_retry_errors = Array(busybee_conf.grpc_retry_errors) if busybee_conf.grpc_retry_errors.presence

        # Client API method defaults
        %i[default_message_ttl default_fail_job_backoff
           default_job_request_timeout default_job_lock_timeout].each do |attr|
          value = busybee_conf.public_send(attr)
          config.public_send(:"#{attr}=", value) if value.presence
        end

        # Worker defaults
        Busybee::Railtie.configure_worker_defaults(config, busybee_conf)
      end
    end

    # @api private
    def self.configure_worker_defaults(config, busybee_conf) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      unless busybee_conf.default_input_required.nil?
        config.default_input_required = !!busybee_conf.default_input_required
      end
      unless busybee_conf.default_output_required.nil?
        config.default_output_required = !!busybee_conf.default_output_required
      end
      unless busybee_conf.default_queue_throttle.nil?
        config.default_queue_throttle = busybee_conf.default_queue_throttle
      end
      config.default_runner_mode = busybee_conf.default_runner_mode if busybee_conf.default_runner_mode.presence
      if busybee_conf.runner_backpressure_delay.presence
        config.runner_backpressure_delay = busybee_conf.runner_backpressure_delay
      end
      if busybee_conf.runner_shutdown_backoff.presence
        config.runner_shutdown_backoff = busybee_conf.runner_shutdown_backoff
      end
      config.shutdown_on_errors = busybee_conf.shutdown_on_errors if busybee_conf.shutdown_on_errors.presence
    end

    # @api private
    def self.configure_credentials(config, busybee_conf)
      # Option 1: Explicit credentials object
      if busybee_conf.credentials.is_a?(Busybee::Credentials)
        config.credentials = busybee_conf.credentials
        return
      end

      # Option 2: Build credentials from type + params (or autodetect from params alone)
      credential_type = busybee_conf.credential_type.presence
      credential_params = extract_credential_params(busybee_conf)

      config.credential_type = credential_type if credential_type
      config.credentials = Busybee::Credentials.build(**credential_params) if credential_params.any?
    end

    # @api private
    def self.extract_credential_params(busybee_conf)
      CREDENTIAL_PARAMS.each_with_object({}) do |param, hash|
        value = busybee_conf.public_send(param)
        hash[param] = value unless value.nil?
      end
    end
  end
end
