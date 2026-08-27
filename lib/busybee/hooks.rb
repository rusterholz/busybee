# frozen_string_literal: true

require "busybee/hooks/chain"
require "busybee/hooks/filters"
require "busybee/worker/shutdown"

module Busybee
  # Hook registration, storage and invocation; prefiltering lives in Filters.
  module Hooks
    # Declared per noun; each callback receives its noun's carrier.
    HOOK_TYPES = %i[
      before_perform around_perform after_perform
      on_job_activated on_job_executed around_job_execution
      on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown
      before_call around_call after_call
    ].freeze

    # Explicit, not derived from the name: the perform triple is named for the
    # usercode lifecycle, but its carrier — and so its filter noun — is the Job.
    HOOK_NOUN = {
      before_perform: :job, around_perform: :job, after_perform: :job,
      on_job_activated: :job, on_job_executed: :job, around_job_execution: :job,
      on_worker_started: :worker, on_worker_stop_requested: :worker,
      on_worker_stopping: :worker, on_worker_shutdown: :worker,
      before_call: :call, around_call: :call, after_call: :call
    }.freeze

    # The allowed filter kwargs per noun; their domains and vocabularies are Filters'.
    FILTER_KEYS = Filters::FILTERS.transform_values { |keys| keys.keys.freeze }.freeze

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
      # @raise [ArgumentError] on a filter that could never match
      def register(type, callback, **filters)
        raise ArgumentError, "#{type} requires a block" unless callback

        filters = filters.compact # a nil filter value means "don't filter on this key"
        Filters.validate!(type, HOOK_NOUN.fetch(type), filters)
        hooks_for(type) << { callback: callback, filters: filters }
      end

      # One registration method per hook type, each taking filter kwargs and a block.
      HOOK_TYPES.each do |type|
        define_method(type) do |**filters, &callback|
          register(type, callback, **filters)
        end
      end

      # ====== Filter matching: Filters owns it, these are its public face ======

      def match?(filter, value) = Filters.match?(filter, value)
      def error_match?(filter, error) = Filters.error_match?(filter, error)
      def matches?(hook, target) = Filters.matches?(hook, target)

      # ====== Invocation ======

      # Run all matching hooks for the given type, each callback receiving the
      # target. Error semantics — propagate by default, log-and-continue with
      # safe: true, shutdown signals excepted — live in protect_allowing_shutdowns.
      def run(type, target, safe: false)
        matching_hooks(type, target).each do |hook|
          protect_allowing_shutdowns(target, safe: safe) { hook[:callback].call(target) }
        end
      end

      # Catch-and-classify for a firing hook. Propagating chains (around_perform)
      # bypass this by design — their errors classify later, at perform_job's
      # rescue, so autofail runs before the Shutdown wrap.
      def protect_allowing_shutdowns(target, safe:)
        yield
      rescue StandardError
        classify_hook_error(target, safe: safe)
      end

      # The one error policy, so it can't drift between invocation sites. MUST be
      # called from within a rescue: it reads the in-flight exception from $!, which
      # is what makes the bare raises re-raise it and the Shutdown wrap pick it up as
      # .cause. Separate from the catch above for Chain, which must catch first.
      def classify_hook_error(target, safe:)
        error = $!
        raise if error.is_a?(Busybee::Worker::Shutdown)

        worker_class = Filters.attribute(target, :worker_class)
        raise Busybee::Worker::Shutdown.new(worker_class: worker_class) if
          Busybee::Worker::Shutdown.triggered_by?(error, worker_class)
        raise unless safe

        log_swallowed_error(error)
      end

      # Log a swallowed hook error, with the first backtrace frame so the operator
      # can locate the offending hook from a single log line.
      def log_swallowed_error(error)
        location = error.backtrace&.first
        suffix = location ? " (at #{location})" : ""
        Busybee.logger&.error("[busybee] Error in hooks (ignored): [#{error.class}] #{error.message}#{suffix}")
      end

      # Run an around-hook chain wrapping a core block; callbacks receive
      # (target, perform). Returns the captured result.
      def run_chain(type, target, safe: false, &block)
        matching = matching_hooks(type, target)
        core = -> { capture_chain_result(target, block.call) }
        Chain.build(matching, target, core, safe: safe).call
        target.is_a?(Busybee::Job) ? target.result : nil
      end

      private

      # Innermost step of run_chain. Guarded because the manual-complete flow may
      # already have captured the result from inside perform, and it is set-once.
      def capture_chain_result(target, raw_result)
        return unless target.is_a?(Busybee::Job)

        resolution = target.send(:resolution)
        resolution.set_result(raw_result) unless resolution.result_set?
      end

      def matching_hooks(type, target)
        hooks_for(type).select { |hook| Filters.matches?(hook, target) }
      end
    end

    reset!
  end
end
