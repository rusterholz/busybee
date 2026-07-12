# frozen_string_literal: true

module Busybee
  # Validated setters for gem-level configuration.
  # Included into Busybee's singleton class; readers live in busybee.rb.
  module Configure # rubocop:disable Metrics/ModuleLength
    # --- String configs ---

    def cluster_address=(value)
      if value.nil?
        @cluster_address = nil
        return
      end

      validate_string!(:cluster_address, value)
      @cluster_address = value.to_s
    end

    def worker_name=(value)
      if value.nil?
        @worker_name = nil
        return
      end

      validate_string!(:worker_name, value)
      @worker_name = value.to_s
    end

    # --- Boolean configs ---

    def default_input_required=(value)
      if value.nil?
        @default_input_required = nil
        return
      end

      validate_boolean!(:default_input_required, value)
      @default_input_required = value
    end

    def default_max_jobs=(value)
      @default_max_jobs = value.nil? ? nil : validate_positive_integer!(:default_max_jobs, value)
    end

    def default_output_required=(value)
      if value.nil?
        @default_output_required = nil
        return
      end

      validate_boolean!(:default_output_required, value)
      @default_output_required = value
    end

    def default_strict_outputs=(value)
      if value.nil?
        @default_strict_outputs = nil
        return
      end

      validate_boolean!(:default_strict_outputs, value)
      @default_strict_outputs = value
    end

    def default_buffer=(value)
      if value.nil?
        @default_buffer = nil
        return
      end

      validate_boolean!(:default_buffer, value)
      @default_buffer = value
    end

    def grpc_retry_enabled=(value)
      if value.nil?
        @grpc_retry_enabled = nil
        return
      end

      validate_boolean!(:grpc_retry_enabled, value)
      @grpc_retry_enabled = value
    end

    # --- Duration configs (Integer ms or ActiveSupport::Duration) ---

    def default_fail_job_backoff=(value)
      @default_fail_job_backoff = value.nil? ? nil : validate_duration!(:default_fail_job_backoff, value)
    end

    def default_job_lock_timeout=(value)
      @default_job_lock_timeout = value.nil? ? nil : validate_duration!(:default_job_lock_timeout, value)
    end

    def default_job_request_timeout=(value)
      @default_job_request_timeout = value.nil? ? nil : validate_duration!(:default_job_request_timeout, value)
    end

    def default_message_ttl=(value)
      @default_message_ttl = value.nil? ? nil : validate_duration!(:default_message_ttl, value)
    end

    def grpc_retry_delay_ms=(value)
      @grpc_retry_delay_ms = value.nil? ? nil : validate_duration!(:grpc_retry_delay_ms, value)
    end

    def default_backpressure_delay=(value)
      @default_backpressure_delay = value.nil? ? nil : validate_duration!(:default_backpressure_delay, value)
    end

    # Keepalive durations carry one extra state beyond the usual nil-resets-to-default:
    # an explicit false disables keepalive. false is stored verbatim (not routed through
    # validate_duration!, which rejects it); nil and everything else behave as normal.
    def grpc_keepalive_interval=(value)
      @grpc_keepalive_interval = keepalive_duration(:grpc_keepalive_interval, value)
    end

    def grpc_keepalive_timeout=(value)
      @grpc_keepalive_timeout = keepalive_duration(:grpc_keepalive_timeout, value)
    end

    # --- Buffer throttle (three-state: false/nil = off, true → 0, Numeric = ms) ---

    def default_buffer_throttle=(value)
      @default_buffer_throttle = value.nil? ? nil : validate_buffer_throttle!(:default_buffer_throttle, value)
    end

    # --- Worker mode ---

    def default_worker_mode=(value)
      if value.nil?
        @default_worker_mode = nil
        return
      end

      validate_worker_mode!(:default_worker_mode, value)
      @default_worker_mode = value.to_sym
    end

    # --- Error class list ---

    def grpc_retry_errors=(value)
      if value.nil?
        @grpc_retry_errors = nil
        return
      end

      validate_error_classes!(:grpc_retry_errors, value)
      @grpc_retry_errors = value
    end

    # --- Backpressure statuses (gRPC status symbols, not classes) ---

    def backpressure_statuses=(value)
      if value.nil?
        @backpressure_statuses = nil
        return
      end

      validate_status_symbols!(:backpressure_statuses, value)
      @backpressure_statuses = value
    end

    # --- Shutdown errors (Array coercion, validates each is StandardError subclass) ---

    def shutdown_on_errors=(value)
      coerced = Array(value)
      coerced.each do |klass|
        unless klass.is_a?(Class) && klass <= StandardError
          raise ArgumentError,
                "shutdown_on_errors expects StandardError subclasses, got #{klass.inspect} (#{klass.class})"
        end
      end
      @shutdown_on_errors = coerced
    end

    # --- Log format ---

    def log_format=(value)
      if value.nil?
        @log_format = nil
        return
      end

      str_value = value.to_s
      if VALID_LOG_FORMATS.include?(str_value)
        @log_format = str_value.to_sym
      else
        Logging.warn("Invalid log_format: #{str_value.inspect}. Valid formats: #{VALID_LOG_FORMATS.join(', ')}")
      end
    end

    # --- Credential type ---

    def credential_type=(value)
      if value.nil?
        @credential_type = nil
        return
      end

      str_value = value.to_s
      if VALID_CREDENTIAL_TYPES.include?(str_value)
        @credential_type = str_value.to_sym
      else
        Logging.warn("Invalid credential_type: #{str_value.inspect}. Valid types: #{VALID_CREDENTIAL_TYPES.join(', ')}")
      end
    end

    # --- Credentials object ---

    def credentials=(value)
      if value.nil?
        @credentials = nil
        return
      end

      unless value.is_a?(Busybee::Credentials)
        raise ArgumentError, "credentials must be a Busybee::Credentials object, got #{value.class}"
      end

      @credentials = value
    end

    private

    # nil (reset to default) and false (disable) pass through untouched; anything
    # else is a normal duration.
    def keepalive_duration(name, value)
      return value if value.nil? || value == false

      validate_duration!(name, value)
    end

    # Validates and coerces a duration config value.
    # Returns the (possibly coerced) value to assign.
    def validate_duration!(name, value) # rubocop:disable Metrics/AbcSize
      return value if value.is_a?(Integer)
      return value if defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration)

      if value.is_a?(String)
        return value.to_f.to_i if value.match?(/\A\d+(\.\d+)?\z/)

        raise ArgumentError,
              "#{name} accepts Integer, ActiveSupport::Duration, or numeric String, " \
              "got non-numeric String #{value.inspect}"
      end

      if value.is_a?(Numeric)
        Logging.warn("#{name}: coercing #{value.class} #{value.inspect} to Integer #{value.to_i}")
        return value.to_i
      end

      raise ArgumentError,
            "#{name} accepts Integer, ActiveSupport::Duration, or numeric String, got #{value.class}"
    end

    def validate_boolean!(name, value)
      return if [true, false].include?(value)

      raise ArgumentError, "#{name} accepts true or false, got #{value.inspect} (#{value.class})"
    end

    def validate_positive_integer!(name, value)
      if value.is_a?(Integer)
        raise ArgumentError, "#{name} must be positive, got #{value}" unless value.positive?

        return value
      end

      if value.is_a?(String) && value.match?(/\A\d+\z/)
        int_value = value.to_i
        raise ArgumentError, "#{name} must be positive, got #{int_value}" unless int_value.positive?

        return int_value
      end

      raise ArgumentError,
            "#{name} accepts a positive Integer or numeric String, got #{value.inspect} (#{value.class})"
    end

    def validate_string!(name, value)
      return if value.is_a?(String) || value.is_a?(Symbol)

      raise ArgumentError, "#{name} accepts String or Symbol, got #{value.inspect} (#{value.class})"
    end

    # Validates and coerces a buffer throttle value.
    # Returns the (possibly coerced) value to assign.
    def validate_buffer_throttle!(name, value)
      return 0 if value == true
      return false if value == false

      if value.is_a?(Numeric)
        raise ArgumentError, "#{name} must be non-negative, got #{value.inspect}" if value.negative?

        return value
      end

      if value.is_a?(String)
        return value.to_f if value.match?(/\A\d+(\.\d+)?\z/)

        raise ArgumentError,
              "#{name} accepts Numeric, boolean, or numeric String, got non-numeric String #{value.inspect}"
      end

      raise ArgumentError, "#{name} accepts Numeric, boolean, or numeric String, got #{value.inspect} (#{value.class})"
    end

    def validate_worker_mode!(name, value)
      sym = value.to_sym
      return if VALID_WORKER_MODES.include?(sym)

      raise ArgumentError,
            "#{name} must be one of #{VALID_WORKER_MODES.map(&:inspect).join(', ')}, got #{value.inspect}"
    rescue NoMethodError
      raise ArgumentError,
            "#{name} accepts Symbol or String, got #{value.inspect} (#{value.class})"
    end

    def validate_error_classes!(name, value)
      raise ArgumentError, "#{name} accepts an Array of exception classes, got #{value.class}" unless value.is_a?(Array)

      value.each do |klass|
        unless klass.is_a?(Class) && klass <= Exception
          raise ArgumentError,
                "#{name} expects exception classes, got #{klass.inspect} (#{klass.class})"
        end
      end
    end

    def validate_status_symbols!(name, value)
      raise ArgumentError, "#{name} accepts an Array of status symbols, got #{value.class}" unless value.is_a?(Array)

      value.each do |status|
        unless status.is_a?(Symbol)
          raise ArgumentError,
                "#{name} expects status symbols (e.g. :resource_exhausted), got #{status.inspect} (#{status.class})"
        end
      end
    end
  end
end
