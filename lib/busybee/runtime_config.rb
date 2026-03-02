# frozen_string_literal: true

require "yaml"

module Busybee
  # Operator-specified runtime configuration, typically from CLI flags or YAML.
  #
  # Two-phase lifecycle:
  #   1. Constructed sparse (only fields the operator explicitly set)
  #   2. After resolve_for(worker_class), fully resolved through the precedence chain:
  #      per-worker RuntimeConfig → global RuntimeConfig → worker DSL → gem defaults
  #
  # Fields are divided into two groups:
  #   - Runner-scoped: participate in the full 4-level precedence chain including
  #     per-worker overrides. Passed to runner constructors.
  #   - Process-wide: resolve at global RC → gem default only (no per-worker step).
  #     Applied to gem-level config before runners start.
  #
  # Runners hold the resolved config at runtime.
  class RuntimeConfig
    VALID_RUNNER_MODES = %i[polling streaming hybrid].freeze
    VALID_LOG_FORMATS = %i[text json].freeze

    # Top-level keys allowed in YAML config (runner-scoped fields + workers).
    RUNNER_SCOPED_KEYS = %i[runner_mode backpressure_delay max_jobs request_timeout
                            queue_enabled queue_throttle job_timeout backoff].freeze
    VALID_YAML_KEYS = (RUNNER_SCOPED_KEYS + %i[workers]).freeze
    PROCESS_WIDE_KEYS = %i[log_format worker_name cluster_address].freeze

    # Parses a YAML config file and returns a kwargs hash suitable for
    # RuntimeConfig.new(**result). Raw YAML types flow through — the
    # constructor handles coercion (e.g., string → symbol for runner_mode).
    def self.parse_yaml(path)
      raw = YAML.safe_load_file(path) || {}
      result = {}

      raw.each do |key, value|
        sym_key = key.to_sym
        validate_yaml_key!(sym_key)
        if sym_key == :workers
          result[:workers] = parse_workers(value)
        else
          result[sym_key] = value
        end
      end

      result
    end

    def self.validate_yaml_key!(key)
      if PROCESS_WIDE_KEYS.include?(key)
        raise ArgumentError, "#{key} is CLI-only and cannot be set in YAML. Use the corresponding CLI flag instead."
      end
      return if VALID_YAML_KEYS.include?(key)

      raise ArgumentError,
            "Unrecognized YAML key: #{key}. Valid keys: #{VALID_YAML_KEYS.join(', ')}"
    end
    private_class_method :validate_yaml_key!

    def self.parse_workers(workers_hash)
      return {} unless workers_hash

      workers_hash.each_with_object({}) do |(name, overrides), acc|
        symbolized = (overrides || {}).transform_keys(&:to_sym)
        validate_worker_override_keys!(name, symbolized)
        acc[name.to_s] = symbolized
      end
    end
    private_class_method :parse_workers

    def self.validate_worker_override_keys!(worker_name, overrides)
      unknown = overrides.keys - RUNNER_SCOPED_KEYS
      return if unknown.empty?

      raise ArgumentError,
            "Unrecognized override keys for #{worker_name}: #{unknown.join(', ')}. " \
            "Valid keys: #{RUNNER_SCOPED_KEYS.join(', ')}"
    end
    private_class_method :validate_worker_override_keys!

    # Runner-scoped fields (CLI: runner_mode only; all configurable via YAML)
    attr_reader :runner_mode, :backpressure_delay, :max_jobs, :request_timeout,
                :queue_enabled, :queue_throttle, :job_timeout, :backoff

    # Process-wide fields
    attr_reader :log_format, :worker_name, :cluster_address

    def initialize(runner_mode: nil, backpressure_delay: nil, max_jobs: nil, # rubocop:disable Metrics/AbcSize,Metrics/ParameterLists
                   request_timeout: nil, queue_enabled: nil, queue_throttle: nil,
                   job_timeout: nil, backoff: nil,
                   log_format: nil, worker_name: nil, cluster_address: nil,
                   workers: {})
      @runner_mode = coerce_symbol!(runner_mode, VALID_RUNNER_MODES, "runner mode") if runner_mode
      @backpressure_delay = backpressure_delay
      @max_jobs = max_jobs
      @request_timeout = request_timeout
      @queue_enabled = queue_enabled
      @queue_throttle = queue_throttle
      @job_timeout = job_timeout
      @backoff = backoff
      @log_format = coerce_symbol!(log_format, VALID_LOG_FORMATS, "log format") if log_format
      @worker_name = worker_name
      @cluster_address = cluster_address
      @workers = workers.each_with_object({}) do |(name, overrides), validated|
        if overrides[:runner_mode]
          mode = coerce_symbol!(overrides[:runner_mode], VALID_RUNNER_MODES, "runner mode")
          overrides = overrides.merge(runner_mode: mode)
        end
        validated[name.to_s] = overrides
      end
    end

    # Resolves configuration for a specific worker class through the full
    # precedence chain. Returns a new RuntimeConfig with all values populated.
    #
    # Runner-scoped fields resolve through 4 levels:
    #   1. Per-worker RuntimeConfig override (highest priority)
    #   2. Global RuntimeConfig value
    #   3. Worker DSL (worker_class.configuration)
    #   4. Gem default (lowest priority)
    #
    # Process-wide fields resolve through 2 levels:
    #   1. Global RuntimeConfig value
    #   2. Gem default
    def resolve_for(worker_class) # rubocop:disable Metrics/AbcSize
      wo = @workers[worker_class.name] || {}
      dsl = worker_class.configuration

      # rubocop:disable Layout/HashAlignment, Layout/LineLength
      self.class.new(
        runner_mode:        first_non_nil(wo[:runner_mode], @runner_mode, dsl.runner_mode, Busybee.default_runner_mode),
        backpressure_delay: first_non_nil(wo[:backpressure_delay], @backpressure_delay, dsl.backpressure_delay, Busybee.runner_backpressure_delay),
        max_jobs:           first_non_nil(wo[:max_jobs], @max_jobs, dsl.polling_config[:max_jobs], Busybee.default_max_jobs),
        request_timeout:    first_non_nil(wo[:request_timeout], @request_timeout, dsl.polling_config[:request_timeout], Busybee.default_job_request_timeout),
        queue_enabled:      first_non_nil(wo[:queue_enabled], @queue_enabled, dsl.streaming_config[:queue], Busybee.default_queue_enabled),
        queue_throttle:     first_non_nil(wo[:queue_throttle], @queue_throttle, dsl.streaming_config[:queue_throttle], Busybee.default_queue_throttle),
        job_timeout:        first_non_nil(wo[:job_timeout], @job_timeout, dsl.job_timeout, Busybee.default_job_lock_timeout),
        backoff:            first_non_nil(wo[:backoff], @backoff, dsl.backoff, Busybee.default_fail_job_backoff),
        log_format:         first_non_nil(@log_format, Busybee.log_format),
        worker_name:        first_non_nil(@worker_name, Busybee.worker_name),
        cluster_address:    first_non_nil(@cluster_address, Busybee.cluster_address)
      )
      # rubocop:enable Layout/HashAlignment, Layout/LineLength
    end

    # Convenience method for runner consumption. Returns polling-relevant fields
    # as a hash matching the shape expected by client.with_each_job.
    def polling_options
      { max_jobs: @max_jobs, request_timeout: @request_timeout, job_timeout: @job_timeout }
    end

    private

    def first_non_nil(*values)
      values.find { |v| !v.nil? }
    end

    def coerce_symbol!(value, valid_set, label)
      sym = value.to_s.to_sym
      return sym if valid_set.include?(sym)

      raise ArgumentError,
            "Invalid #{label}: #{value.inspect}. Valid: #{valid_set.map(&:inspect).join(', ')}"
    end
  end
end
