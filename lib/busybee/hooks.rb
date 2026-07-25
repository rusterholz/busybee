# frozen_string_literal: true

require "busybee/hooks/chain"

module Busybee
  # Central module for the hook/instrumentation system.
  # Provides hook registration and storage, prefilter matching, and
  # invocation (propagating and swallowing).
  module Hooks
    # Hook types are declared per noun. The :job and :worker hooks are wired
    # end-to-end (jobs through the Worker/Runner job path; the four worker
    # moments through Runner#run! / #stop! with a Worker::Status carrier). The
    # :call entries fire through the Client::Call seam. Each callback receives
    # its noun's carrier: Job, Worker::Status, or Client::Call.
    HOOK_TYPES = %i[
      before_perform around_perform after_perform
      on_job_activated on_job_executed around_job_execution
      on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown
      before_call around_call after_call
    ].freeze

    # Allowed filter kwargs per noun. Each key is resolved against the carrier
    # via public_send at match time, so every key here must be a public reader
    # on the noun's carrier (Worker::Status for :worker).
    FILTER_KEYS = {
      job: %i[job_type worker_class status bpmn_process_id source buffered error].freeze,
      worker: %i[worker_class job_type worker_mode reason error error_class].freeze,
      call: %i[rpc status grpc_status error_class].freeze
    }.freeze

    # Map each hook type to its noun for filter validation. Explicit, not derived
    # from the name: the perform triple carries the usercode lifecycle's name
    # ("perform" = wraps usercode; "job" = the system's job lifecycle), while its
    # carrier — and so its filter noun — is still the Job.
    HOOK_NOUN = {
      before_perform: :job, around_perform: :job, after_perform: :job,
      on_job_activated: :job, on_job_executed: :job, around_job_execution: :job,
      on_worker_started: :worker, on_worker_stop_requested: :worker,
      on_worker_stopping: :worker, on_worker_shutdown: :worker,
      before_call: :call, around_call: :call, after_call: :call
    }.freeze

    class << self
      # ====== Hook storage ======

      # @return [Array] the hooks array for the given type
      def hooks_for(type)
        unless HOOK_TYPES.include?(type)
          raise ArgumentError, "Unknown hook type: #{type.inspect}. Expected one of: #{HOOK_TYPES.join(', ')}"
        end

        @hooks[type]
      end

      # Clear all registered hooks. Intended for test isolation.
      def reset!
        @hooks = HOOK_TYPES.to_h { |type| [type, []] }
      end

      # ====== Registration ======

      # Register a hook. Called by delegation methods on the Busybee singleton.
      #
      # @param type [Symbol] one of HOOK_TYPES
      # @param filters [Hash] optional prefilter kwargs
      # @param callback [Proc] the hook block
      def register(type, callback, **filters)
        raise ArgumentError, "#{type} requires a block" unless callback

        validate_filters!(type, filters)
        hooks_for(type) << { callback: callback, filters: filters }
      end

      # Define one registration method per hook type.
      # Each accepts optional filter kwargs and a required block.
      HOOK_TYPES.each do |type|
        define_method(type) do |**filters, &callback|
          register(type, callback, **filters)
        end
      end

      # ====== Filter matching ======

      # Test whether a single filter matches a value.
      #
      # An Array filter matches if any of its elements matches (match-any), so
      # `job_type: %w[create_shipment assign_driver]` fires for either. Each
      # element is matched by the same rules, so arrays can mix matchers.
      #
      # A scalar filter matches in three layers:
      #   1. Case equality (===) — Symbol/String exact match, Regexp pattern,
      #      Class is_a?, Proc/Lambda custom logic.
      #   2. Equality (==) — catches direct identity, notably Class === Class
      #      (where === would check is_a? on the class object, not identity).
      #      So `worker_class: OrderWorker` matches as expected.
      #   3. Class name fallback — when value is a Class, also match the filter
      #      against value.name. Lets `worker_class: /Order/` match class names.
      #
      # @param filter [Object] the filter (Array, Symbol, String, Regexp, Class, Proc, etc.)
      # @param value [Object] the value from the event
      # @return [Boolean]
      def match?(filter, value)
        return filter.any? { |element| match?(element, value) } if filter.is_a?(Array)

        filter === value ||
          filter == value ||
          (value.is_a?(Class) && filter === value.name)
      end

      # Test whether all of a hook's filters match the given target. The target
      # is a Job for job-noun hooks; filter keys are looked up as job attributes
      # (via public_send). Returns true (vacuous truth) when filters are empty.
      #
      # @param hook [Hash] { callback:, filters: }
      # @param target [Object] the noun (Busybee::Job for job hooks)
      # @return [Boolean]
      def matches?(hook, target)
        hook[:filters].all? { |key, filter| match?(filter, attribute(target, key)) }
      end

      # ====== Invocation ======

      # Run all matching hooks for the given type. Callbacks receive the target
      # (e.g. Busybee::Job for job-noun hooks).
      #
      # By default, errors propagate (for wrapping hooks like before_perform).
      # With safe: true, errors are logged and iteration continues (for
      # observing hooks like after_perform, on_job_executed). Shutdown errors
      # always propagate regardless of the safe: flag.
      def run(type, target, safe: false)
        matching_hooks(type, target).each do |hook|
          hook[:callback].call(target)
        rescue Busybee::Worker::Shutdown
          raise
        rescue StandardError => e
          raise Busybee::Worker::Shutdown.new(worker: nil) if shutdown_error?(e, target)
          raise unless safe

          log_swallowed_error(e)
        end
      end

      # Log a hook error that was swallowed (in safe-mode iteration or safe
      # around-chain). Includes class, message, and the first backtrace frame
      # so the operator can locate the offending hook from a single log line.
      def log_swallowed_error(error)
        location = error.backtrace&.first
        suffix = location ? " (at #{location})" : ""
        Busybee.logger&.error("[busybee] Error in hooks (ignored): [#{error.class}] #{error.message}#{suffix}")
      end

      # Run an around-hook chain wrapping a core block. Middleware callbacks
      # receive (target, perform). The chain return value is the captured
      # result (HWIA-coerced for job-noun chains via Resolution#set_result).
      def run_chain(type, target, safe: false, &block)
        matching = matching_hooks(type, target)
        core = -> { capture_chain_result(target, block.call) }
        Chain.build(matching, target, core, safe: safe).call
        target.is_a?(Busybee::Job) ? target.result : nil
      end

      private

      # Innermost step of run_chain. For job-noun chains, captures the
      # perform-returned result onto Job's Resolution (set-once + HWIA + freeze)
      # if it isn't already set; the manual-complete flow may have captured it
      # earlier from inside perform.
      def capture_chain_result(target, raw_result)
        return unless target.is_a?(Busybee::Job)

        resolution = target.send(:resolution)
        resolution.set_result(raw_result) unless resolution.result_set?
      end

      def validate_filters!(type, filters)
        return if filters.empty?

        allowed = FILTER_KEYS[HOOK_NOUN[type]]
        unknown = filters.keys - allowed
        return if unknown.empty?

        raise ArgumentError,
              "Unknown filter(s) for #{type}: #{unknown.join(', ')}. " \
              "Allowed: #{allowed.join(', ')}"
      end

      def matching_hooks(type, target)
        hooks_for(type).select { |h| matches?(h, target) }
      end

      # Look up a filter key against the target. For job-noun hooks the target
      # is a Busybee::Job; attribute names map to public methods. Missing keys
      # return nil so a hook can express "filter only fires when this attribute
      # is non-nil" without needing a separate predicate.
      def attribute(target, key)
        target.respond_to?(key) ? target.public_send(key) : nil
      end

      # Check if an error matches shutdown_on classes from the worker or gem config.
      def shutdown_error?(error, target)
        worker_class = attribute(target, :worker_class)
        per_worker = worker_class.respond_to?(:configuration) ? worker_class.configuration.shutdown_on : []
        (per_worker + Busybee.shutdown_on_errors).any? { |klass| error.is_a?(klass) }
      end
    end

    reset!
  end
end
