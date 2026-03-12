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
  #   - Worker-scoped: participate in the full 4-level precedence chain including
  #     per-worker overrides. Passed to runner constructors.
  #   - Process-wide: resolve at global RC → gem default only (no per-worker step).
  #     Applied to gem-level config before runners start.
  #
  # Runners hold the resolved config at runtime.
  class RuntimeConfig
    VALID_WORKER_MODES = %i[polling streaming hybrid].freeze
    VALID_LOG_FORMATS = %i[text json].freeze

    # Top-level keys allowed in YAML config (worker-scoped fields + workers).
    WORKER_SCOPED_KEYS = %i[worker_mode backpressure_delay max_jobs request_timeout
                            buffer buffer_throttle job_timeout backoff].freeze
    VALID_YAML_KEYS = (WORKER_SCOPED_KEYS + %i[workers]).freeze
    PROCESS_WIDE_KEYS = %i[log_format worker_name cluster_address].freeze

    # Parses a YAML config file and returns a kwargs hash suitable for
    # RuntimeConfig.new(**result). Raw YAML types flow through — the
    # constructor handles coercion (e.g., string → symbol for worker_mode).
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

    def self.parse_workers(workers_list)
      return {} unless workers_list

      workers_list.each_with_object({}) do |entry, acc|
        name, overrides = case entry
                          when String then [entry, {}]
                          when Hash   then extract_worker_entry(entry)
                          end
        validate_worker_override_keys!(name, overrides)
        acc[name.to_s] = overrides
      end
    end
    private_class_method :parse_workers

    # A worker entry hash comes in two forms depending on YAML indentation:
    #   Nested:  { "Worker" => { "max_jobs" => 32 } }
    #   Flat:    { "Worker" => nil, "max_jobs" => 32 }
    def self.extract_worker_entry(hash)
      first_key, first_value = hash.first
      if first_value.is_a?(Hash)
        [first_key, first_value.transform_keys(&:to_sym)]
      else
        overrides = hash.compact.transform_keys(&:to_sym)
        [first_key, overrides]
      end
    end
    private_class_method :extract_worker_entry

    def self.validate_worker_override_keys!(worker_name, overrides)
      unknown = overrides.keys - WORKER_SCOPED_KEYS
      return if unknown.empty?

      raise ArgumentError,
            "Unrecognized override keys for #{worker_name}: #{unknown.join(', ')}. " \
            "Valid keys: #{WORKER_SCOPED_KEYS.join(', ')}"
    end
    private_class_method :validate_worker_override_keys!

    # Worker-scoped fields (CLI: worker_mode only; all configurable via YAML)
    attr_reader :worker_mode, :backpressure_delay, :max_jobs, :request_timeout,
                :buffer, :buffer_throttle, :job_timeout, :backoff

    # Process-wide fields
    attr_reader :log_format, :worker_name, :cluster_address

    def initialize(worker_mode: nil, backpressure_delay: nil, max_jobs: nil, # rubocop:disable Metrics/AbcSize,Metrics/ParameterLists
                   request_timeout: nil, buffer: nil, buffer_throttle: nil,
                   job_timeout: nil, backoff: nil,
                   log_format: nil, worker_name: nil, cluster_address: nil,
                   workers: {})
      @worker_mode = coerce_symbol!(worker_mode, VALID_WORKER_MODES, "worker mode") if worker_mode
      @backpressure_delay = backpressure_delay
      @max_jobs = max_jobs
      @request_timeout = request_timeout
      @buffer = buffer
      @buffer_throttle = buffer_throttle
      @job_timeout = job_timeout
      @backoff = backoff
      @log_format = coerce_symbol!(log_format, VALID_LOG_FORMATS, "log format") if log_format
      @worker_name = worker_name
      @cluster_address = cluster_address
      @workers = workers.each_with_object({}) do |(name, overrides), validated|
        if overrides[:worker_mode]
          mode = coerce_symbol!(overrides[:worker_mode], VALID_WORKER_MODES, "worker mode")
          overrides = overrides.merge(worker_mode: mode)
        end
        validated[name.to_s] = overrides
      end
    end

    # Resolves configuration for a specific worker class through the full
    # precedence chain. Returns a new RuntimeConfig with all values populated.
    #
    # Worker-scoped fields resolve through 4 levels:
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
        worker_mode:        first_non_nil(wo[:worker_mode], @worker_mode, dsl.worker_mode, Busybee.default_worker_mode),
        backpressure_delay: first_non_nil(wo[:backpressure_delay], @backpressure_delay, dsl.backpressure_delay, Busybee.default_backpressure_delay),
        max_jobs:           first_non_nil(wo[:max_jobs], @max_jobs, dsl.polling_config[:max_jobs], Busybee.default_max_jobs),
        request_timeout:    first_non_nil(wo[:request_timeout], @request_timeout, dsl.polling_config[:request_timeout], Busybee.default_job_request_timeout),
        buffer:     first_non_nil(wo[:buffer], @buffer, dsl.streaming_config[:buffer], Busybee.default_buffer),
        buffer_throttle:    first_non_nil(wo[:buffer_throttle], @buffer_throttle, dsl.streaming_config[:buffer_throttle], Busybee.default_buffer_throttle),
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
