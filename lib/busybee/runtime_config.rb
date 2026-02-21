# frozen_string_literal: true

module Busybee
  # Operator-specified runtime configuration, typically from CLI flags or YAML.
  #
  # Two-phase lifecycle:
  #   1. Constructed sparse (only fields the operator explicitly set)
  #   2. After for_worker(worker_class), fully resolved through the precedence chain:
  #      per-worker RuntimeConfig → global RuntimeConfig → worker DSL → gem defaults
  #
  # Runners hold the resolved config at runtime.
  class RuntimeConfig
    VALID_RUNNER_MODES = %i[polling streaming hybrid].freeze

    attr_reader :runner_mode

    def initialize(runner_mode: nil, workers: {})
      validate_runner_mode!(runner_mode) if runner_mode
      @runner_mode = runner_mode
      @workers = workers.each_with_object({}) do |(name, overrides), validated|
        validate_runner_mode!(overrides[:runner_mode]) if overrides[:runner_mode]
        validated[name.to_s] = overrides
      end
    end

    # Resolves configuration for a specific worker class through the full
    # precedence chain. Returns a new RuntimeConfig with all values populated.
    #
    # Resolution order (highest to lowest priority):
    #   1. Per-worker RuntimeConfig override
    #   2. Global RuntimeConfig value
    #   3. Worker DSL (worker_class.configuration)
    #   4. Gem default (Busybee.default_runner_mode)
    def resolve_for(worker_class)
      worker_overrides = @workers[worker_class.name] || {}

      resolved_mode = worker_overrides[:runner_mode] ||
                      @runner_mode ||
                      worker_class.configuration.runner_mode ||
                      Busybee.default_runner_mode

      self.class.new(runner_mode: resolved_mode)
    end

    private

    def validate_runner_mode!(value)
      return if VALID_RUNNER_MODES.include?(value)

      raise ArgumentError,
            "Invalid runner mode: #{value.inspect}. Valid: #{VALID_RUNNER_MODES.map(&:inspect).join(', ')}"
    end
  end
end
