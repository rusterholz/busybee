# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/serialization"
require "busybee/hooks/restricted_access"
require "busybee/hooks/job_event_access"
require "busybee/hooks/worker_event_access"
require "busybee/hooks/call_event_access"

module Busybee
  # Central module for the hook/instrumentation system.
  # Provides event construction, hook registration and storage,
  # prefilter matching, and invocation (propagating and swallowing).
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

    # Context keys that can be promoted from thread-local context to event
    # top level per noun. Only stable-across-scope identity keys belong here;
    # per-moment keys (timestamps, status, result, error) stay explicit.
    # Non-promoted context keys are still visible via event[:context].
    CONTEXT_KEYS = {
      job: %i[worker_class worker job job_type job_key bpmn_process_id
              process_instance_key element_id].freeze,
      worker: %i[worker_class job_type worker_mode].freeze,
      call: %i[].freeze
    }.freeze

    CONTEXT_THREAD_KEY = :_busybee_hooks_context

    NOUN_EVENT_ACCESS = {
      job: JobEventAccess,
      worker: WorkerEventAccess,
      call: CallEventAccess
    }.freeze

    # Returns the current thread-local hook context.
    # @return [Hash]
    def self.context
      Thread.current[CONTEXT_THREAD_KEY] || {}
    end

    # Push context for the duration of a block. Merges with any existing
    # context (inner values win). Restores previous context on block exit.
    def self.with_context(**attrs)
      previous = Thread.current[CONTEXT_THREAD_KEY]
      Thread.current[CONTEXT_THREAD_KEY] = (previous || {}).merge(attrs)
      yield
    ensure
      Thread.current[CONTEXT_THREAD_KEY] = previous
    end

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

    # Run all matching hooks for the given type.
    #
    # By default, errors propagate (for wrapping hooks like before_job, around_call).
    # With swallow_errors: true, errors are logged and iteration continues
    # (for observing hooks like after_job, on_worker_started). Shutdown errors
    # always propagate regardless of swallow_errors.
    #
    # @param type [Symbol] hook type
    # @param event [Hash] the event hash
    # @param swallow_errors [Boolean] whether to swallow non-shutdown errors
    # Returns hooks for the given type that match the event's current state.
    def self.matching_hooks(type, event)
      hooks_for(type).select { |h| matches?(h, event) }
    end
    private_class_method :matching_hooks

    def self.run_hooks(type, event, swallow_errors: false)
      matching_hooks(type, event).each do |hook|
        hook[:callback].call(event)
      rescue Busybee::Worker::Shutdown
        raise
      rescue StandardError => e
        raise Busybee::Worker::Shutdown.new(worker: event[:worker]) if shutdown_error?(e, event)
        raise unless swallow_errors

        Busybee.logger&.error("[busybee] Hook error (swallowed): #{e.class}: #{e.message}")
      end
    end

    # Check if an error matches shutdown_on classes from the worker or gem config.
    def self.shutdown_error?(error, event)
      worker_class = event[:worker_class]
      per_worker = worker_class.respond_to?(:configuration) ? worker_class.configuration.shutdown_on : []
      (per_worker + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
    end
    private_class_method :shutdown_error?

    # Run an around-hook chain wrapping a core block (Option B2).
    #
    # Builds a nested chain from matching around hooks via reverse.inject.
    # The core block's return value is stored in event[:result] (a sealed key
    # present from event construction). The chain's own return value is ignored,
    # preventing the "forgetful middleware" bug.
    #
    # @param type [Symbol] hook type (e.g. :around_job)
    # @param event [Hash] the event hash (must have :result key)
    # @yield the core block to wrap
    def self.run_around_chain(type, event, &block)
      matching = matching_hooks(type, event)

      core = lambda do
        result = block.call
        event[:result].merge!(result) if result.is_a?(Hash)
      end

      chain = matching.reverse.inject(core) do |next_link, hook|
        -> { hook[:callback].call(event, next_link) }
      end

      chain.call
    end

    # Build a hook event object for the given noun.
    #
    # Merges thread-local context into the event, filtered by CONTEXT_KEYS
    # for the noun (only allowed identity keys are promoted). Explicit data
    # always wins over context. Full context is stashed as a frozen hash
    # under the :context key for inspection.
    #
    # @param noun [Symbol] :job, :worker, or :call
    # @param data [Hash] framework keys for the event
    # @return [ActiveSupport::HashWithIndifferentAccess]
    def self.build_event(noun, data) # rubocop:disable Metrics/AbcSize
      event_access = NOUN_EVENT_ACCESS.fetch(noun) do
        raise ArgumentError, "Unknown hook noun: #{noun.inspect}. Expected one of: #{NOUN_EVENT_ACCESS.keys.join(', ')}"
      end

      ActiveSupport::HashWithIndifferentAccess.new(
        context.slice(*CONTEXT_KEYS[noun]).merge(data)
      ).tap { |e| e[:context] = context.dup.with_indifferent_access.freeze }.
        extend(Busybee::Serialization::HashAccess).
        extend(RestrictedAccess).
        extend(event_access)
    end
  end
end
