# frozen_string_literal: true

module Busybee
  module Hooks
    # Builds the nested lambda chain used by Hooks.run_chain. Each hook receives
    # (target, perform); calling perform descends one step and returns the core's
    # value, whatever the hooks below it return. Chain owns only composition (the
    # nesting, the called-flag, the forced continuation); what a raise means is
    # Hooks' policy, shared with the flat hook runs.
    module Chain
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
              called = false
              value = nil
              wrapped = lambda {
                called = true
                value = next_link.call
              }
              hook[:callback].call(target, wrapped)
              force_continuation(hook, wrapped) unless called
              value
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
            called = false
            value = error_from_below = nil
            # Identity, not class: a hook raising its own error after a good descent owns it.
            wrapped = lambda do
              called = true
              value = next_link.call
            rescue StandardError => e
              error_from_below = e
              raise
            end

            begin
              hook[:callback].call(target, wrapped)
              force_continuation(hook, wrapped) unless called
            rescue StandardError => e
              raise if e.equal?(error_from_below)

              Hooks.classify_hook_error(target, safe: true)
            end
            wrapped.call unless called # a swallowed pre-yield error must not cancel downstream
            value
          end
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
        def force_continuation(hook, wrapped)
          log_forgotten_yield(hook[:callback])
          wrapped.call
        end

        def log_forgotten_yield(callback)
          location = callback.source_location&.join(":")
          suffix = location ? " (at #{location})" : ""
          Busybee.logger&.warn(
            "[busybee] Around-hook returned without yielding; " \
            "forcing continuation#{suffix}"
          )
        end
      end
    end
  end
end
