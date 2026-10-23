# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "rails"
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

    # Settings the busybee command may have applied from its flags or YAML before Rails booted.
    PROCESS_WIDE_SETTINGS = %i[log_format cluster_address worker_name shutdown_wait_timeout].freeze

    initializer "busybee.configure" do
      Busybee.configure do |config|
        busybee_conf = Rails.configuration.x.busybee

        # Logger: custom if set, nil if explicitly false; Rails.logger if true, or
        # by default when no logger was configured before boot
        case busybee_conf&.logger
        when false then config.logger = nil
        when true then config.logger = Rails.logger
        when nil then config._default_logger = Rails.logger
        else config.logger = busybee_conf.logger
        end

        next unless busybee_conf.presence

        PROCESS_WIDE_SETTINGS.each do |field|
          value = busybee_conf.public_send(field)
          Busybee::Railtie.apply_over_cli(config, field, value) if value.present?
        end

        # Credentials: explicit object, or build from type + params
        Busybee::Railtie.configure_credentials(config, busybee_conf)

        # GRPC transport: retry + channel keepalive
        Busybee::Railtie.configure_grpc(config, busybee_conf)

        # Client API method defaults
        %i[default_message_ttl default_fail_job_backoff
           default_polling_request_timeout default_job_timeout].each do |attr|
          value = busybee_conf.public_send(attr)
          config.public_send(:"#{attr}=", value) if value.presence
        end

        # Worker defaults
        Busybee::Railtie.configure_worker_defaults(config, busybee_conf)
      end
    end

    # Applies a process-wide setting, saying so when it replaces what the busybee command applied.
    # @api private
    def self.apply_over_cli(config, field, value)
      source, replaced = config._cli_source(field)
      config.public_send(:"#{field}=", value)
      applied = config.public_send(field)
      return if source.nil? || applied == replaced

      Busybee::Logging.info("Overriding #{source} #{replaced.inspect} " \
                            "with config.x.busybee.#{field} #{applied.inspect}")
    end

    # @api private
    def self.configure_grpc(config, busybee_conf) # rubocop:disable Metrics/AbcSize
      config.grpc_retry_enabled = !!busybee_conf.grpc_retry_enabled unless busybee_conf.grpc_retry_enabled.nil?
      config.grpc_retry_delay = busybee_conf.grpc_retry_delay if busybee_conf.grpc_retry_delay.presence
      config.grpc_retry_errors = Array(busybee_conf.grpc_retry_errors) if busybee_conf.grpc_retry_errors.presence

      # Keepalive guards on nil, not presence: false is a real value (disable).
      unless busybee_conf.grpc_keepalive_interval.nil?
        config.grpc_keepalive_interval = busybee_conf.grpc_keepalive_interval
      end
      return if busybee_conf.grpc_keepalive_timeout.nil?

      config.grpc_keepalive_timeout = busybee_conf.grpc_keepalive_timeout
    end

    # @api private
    def self.configure_worker_defaults(config, busybee_conf) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      unless busybee_conf.default_input_required.nil?
        config.default_input_required = !!busybee_conf.default_input_required
      end
      unless busybee_conf.default_output_required.nil?
        config.default_output_required = !!busybee_conf.default_output_required
      end
      unless busybee_conf.default_strict_outputs.nil?
        config.default_strict_outputs = !!busybee_conf.default_strict_outputs
      end
      config.default_buffer = !!busybee_conf.default_buffer unless busybee_conf.default_buffer.nil?
      unless busybee_conf.default_buffer_throttle.nil?
        config.default_buffer_throttle = busybee_conf.default_buffer_throttle
      end
      %i[default_max_jobs default_worker_mode default_backpressure_delay].each do |attr|
        value = busybee_conf.public_send(attr)
        config.public_send(:"#{attr}=", value) if value.presence
      end
      config.backpressure_statuses = busybee_conf.backpressure_statuses if busybee_conf.backpressure_statuses.present?
      config.shutdown_on_errors = busybee_conf.shutdown_on_errors if busybee_conf.shutdown_on_errors.presence
    end

    # An explicit credentials object, else credentials built from type + params
    # (or autodetected from params alone).
    # @api private
    def self.configure_credentials(config, busybee_conf)
      if busybee_conf.credentials.is_a?(Busybee::Credentials)
        config.credentials = busybee_conf.credentials
        return
      end

      credential_type = busybee_conf.credential_type.presence
      credential_params = extract_credential_params(busybee_conf)

      config.credential_type = credential_type if credential_type
      config.credentials = Busybee::Credentials.build(**credential_params) if credential_params.any?
    end

    # @api private
    def self.extract_credential_params(busybee_conf)
      CREDENTIAL_PARAMS.each_with_object({}) do |param, hash|
        value = busybee_conf.public_send(param)
        hash[param] = value unless value.to_s.blank? # to_s: a Pathname's blank? asks the filesystem
      end
    end
  end
end
