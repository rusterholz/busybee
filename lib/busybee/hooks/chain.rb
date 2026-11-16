# frozen_string_literal: true

require "busybee/logging"

module Busybee
  module Hooks
    # Builds the nested lambda chain used by Hooks.run_chain. Each hook receives
    # (target, perform); calling perform descends one step and returns the core's
    # value, whatever the hooks below it return. Chain owns only composition (the
    # nesting, the once-only descent, the forced continuation); what a raise means
    # is Hooks' policy, shared with the flat hook runs.
    module Chain
      # One link invocation's descent: whether the hook has yielded, and what the
      # first descent returned or raised.
      Descent = Struct.new(:called, :value, :error)
      private_constant :Descent

      class << self
        # @param hooks [Array<Hash>] matching hooks, each with :callback
        # @param target [Object] the hook noun (Busybee::Job for job hooks)
        # @param core [Proc] the innermost lambda
        # @param safe [Boolean] swallow non-shutdown errors when true
        # @return [Proc] the assembled chain
        def build(hooks, target, core, safe:)
          if safe
            build_safe(hooks, target, core)
          else
            build_propagating(hooks, target, core)
          end
        end

        private

        # Propagating links (around_perform) hand errors raw to perform_job's
        # rescue, which must autofail before any Shutdown wrap, so they bypass
        # protect_allowing_shutdowns. A raise aborts; a clean return without
        # yielding is forced on, since resolving the job is the only short-circuit.
        def build_propagating(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            lambda do
              descent = Descent.new(false)
              continuation = continuation(next_link, hook, target, descent)
              hook[:callback].call(target, continuation)
              force_continuation(hook, continuation, target) unless descent.called
              descent.value
            end
          end
        end

        # Observing links: a hook raising or not yielding must not stop the hooks
        # below it or the core. A link classifies only its own error; one passing
        # through on the way up belongs to whoever raised it.
        def build_safe(hooks, target, core)
          hooks.reverse.inject(classifying(core, target)) do |next_link, hook|
            safe_link(next_link, hook, target)
          end
        end

        # One observing link; its state is per invocation, so it lives inside.
        def safe_link(next_link, hook, target)
          lambda do
            descent = Descent.new(false)
            continuation = continuation(next_link, hook, target, descent)
            begin
              hook[:callback].call(target, continuation)
              force_continuation(hook, continuation, target) unless descent.called
            rescue StandardError => e
              raise if e.equal?(descent.error) # identity, not class: a hook's own error after a good descent is its own

              Hooks.classify_hook_error(target, safe: true)
            end
            continuation.call unless descent.called # a swallowed pre-yield error must not cancel downstream
            descent.value
          end
        end

        # The hook's perform/continue: descends once; a repeat re-delivers the
        # first descent's value, or re-raises its error, and says so.
        def continuation(next_link, hook, target, descent)
          lambda do
            return repeated_continuation(hook, target, descent) if descent.called

            descent.called = true
            descent.value = next_link.call
          rescue Exception => e # rubocop:disable Lint/RescueException
            descent.error ||= e
            raise
          end
        end

        def repeated_continuation(hook, target, descent)
          Logging.warn("Ignoring repeated continuation call from an around-hook#{location_suffix(hook[:callback])}",
                       target, error: descent.error)
          raise descent.error if descent.error

          descent.value
        end

        # The classification boundary, beneath every link so it exists with no
        # hooks registered: whether an error is fatal is a property of (error,
        # worker), never of who was listening. Never swallows.
        def classifying(core, target)
          lambda do
            core.call
          rescue StandardError
            Hooks.classify_hook_error(target, safe: false)
          end
        end

        # The chain always descends: run the skipped continuation, and say so.
        def force_continuation(hook, wrapped, target)
          log_forgotten_yield(hook[:callback], target)
          wrapped.call
        end

        def log_forgotten_yield(callback, target)
          Logging.warn("Forcing continuation past an around-hook that returned without yielding" \
                       "#{location_suffix(callback)}", target)
        end

        def location_suffix(callback)
          location = callback.source_location&.join(":")
          location ? " (at #{location})" : ""
        end
      end
    end
  end
end
