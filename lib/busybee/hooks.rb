# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/serialization"
require "busybee/hooks/restricted_access"
require "busybee/hooks/job_event_access"
require "busybee/hooks/worker_event_access"
require "busybee/hooks/call_event_access"

module Busybee
  # Central module for the hook/instrumentation system.
  # Provides event construction, and will gain hook registration,
  # storage, and invocation in subsequent missions.
  module Hooks
    HOOK_TYPES = %i[
      before_job around_job after_job
      on_job_activated on_job_executed around_job_execution
      on_worker_started on_worker_stopping on_worker_shutdown
      before_call around_call after_call
    ].freeze

    # Allowed filter kwargs per noun
    FILTER_KEYS = {
      job: %i[job_type worker_class status bpmn_process_id error].freeze,
      worker: %i[worker_class job_type worker_mode error].freeze,
      call: %i[method result error].freeze
    }.freeze

    # Map each hook type to its noun for filter validation
    HOOK_NOUN = HOOK_TYPES.each_with_object({}) do |type, h|
      noun = case type
             when /job/ then :job
             when /worker/ then :worker
             when /call/ then :call
             end
      h[type] = noun
    end.freeze

    NOUN_EVENT_ACCESS = {
      job: JobEventAccess,
      worker: WorkerEventAccess,
      call: CallEventAccess
    }.freeze

    # @return [Array] the hooks array for the given type
    def self.hooks_for(type)
      unless HOOK_TYPES.include?(type)
        raise ArgumentError, "Unknown hook type: #{type.inspect}. Expected one of: #{HOOK_TYPES.join(', ')}"
      end

      @hooks[type]
    end

    # Clear all registered hooks. Intended for test isolation.
    def self.reset!
      @hooks = HOOK_TYPES.each_with_object({}) { |type, h| h[type] = [] }
    end

    reset!

    # Register a hook. Called by delegation methods on the Busybee singleton.
    #
    # @param type [Symbol] one of HOOK_TYPES
    # @param filters [Hash] optional prefilter kwargs
    # @param callback [Proc] the hook block
    def self.register(type, callback, **filters)
      raise ArgumentError, "#{type} requires a block" unless callback

      validate_filters!(type, filters)
      hooks_for(type) << { callback: callback, filters: filters }
    end

    def self.validate_filters!(type, filters)
      return if filters.empty?

      allowed = FILTER_KEYS[HOOK_NOUN[type]]
      unknown = filters.keys - allowed
      return if unknown.empty?

      raise ArgumentError,
            "Unknown filter(s) for #{type}: #{unknown.join(', ')}. " \
            "Allowed: #{allowed.join(', ')}"
    end
    private_class_method :validate_filters!

    # Define registration methods for all hook types.
    # Each method accepts optional filter kwargs and a required block.
    HOOK_TYPES.each do |type|
      define_singleton_method(type) do |**filters, &callback|
        register(type, callback, **filters)
      end
    end

    # Test whether a single filter matches a value using case equality (===).
    # Falls back to matching against value.name when value is a Class,
    # allowing e.g. `worker_class: /Order/` to match class name strings.
    #
    # @param filter [Object] the filter (Symbol, String, Regexp, Class, Proc, etc.)
    # @param value [Object] the value from the event
    # @return [Boolean]
    def self.match?(filter, value)
      filter === value || (value.is_a?(Class) && filter === value.name)
    end

    # Test whether all of a hook's filters match the given event.
    # Returns true (vacuous truth) when filters are empty.
    #
    # @param hook [Hash] { callback:, filters: }
    # @param event [Hash] the event hash
    # @return [Boolean]
    def self.matches?(hook, event)
      hook[:filters].all? { |key, filter| match?(filter, event[key.to_s]) }
    end

    # Build a hook event object for the given noun.
    #
    # Returns a HashWithIndifferentAccess extended with HashAccess (method-style
    # access), RestrictedAccess (framework keys locked), and the noun-specific
    # EventAccess mixin (predicates, durations, tags).
    #
    # @param noun [Symbol] :job, :worker, or :call
    # @param data [Hash] framework keys for the event
    # @return [ActiveSupport::HashWithIndifferentAccess]
    def self.build_event(noun, data)
      event_access = NOUN_EVENT_ACCESS.fetch(noun) do
        raise ArgumentError, "Unknown hook noun: #{noun.inspect}. Expected one of: #{NOUN_EVENT_ACCESS.keys.join(', ')}"
      end

      ActiveSupport::HashWithIndifferentAccess.new(data).
        extend(Busybee::Serialization::HashAccess).
        extend(RestrictedAccess).
        extend(event_access)
    end
  end
end
