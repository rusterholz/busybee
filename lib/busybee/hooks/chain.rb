# frozen_string_literal: true

require "busybee/worker/shutdown"

module Busybee
  module Hooks
    # Builds the nested lambda chain used by Hooks.run_chain.
    # Each hook receives (target, perform); calling perform descends one
    # step. The core block sits at the chain's center.
    #
    # Chain owns only composition — nesting, the called-flag, the forced
    # continuation. What happens when a link raises is Hooks'
    # protect_allowing_shutdowns policy, shared with the flat hook runs.
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

        # No rescue here by design: a propagating chain (around_perform) hands
        # errors raw to perform_job's rescue, which must run autofail before
        # any Shutdown wrap — don't route these links through
        # protect_allowing_shutdowns.
        #
        # Forced continuation applies here too, on the clean-return path only.
        # The chain always descends; whether work happens is decided by the
        # job's ready? gate at the core. There is one way to short-circuit a
        # job — resolve it — and skipping the yield isn't it. Raising still
        # aborts, because a raise never reaches the forcing branch.
        def build_propagating(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            lambda do
              called = false
              wrapped = lambda {
                called = true
                next_link.call
              }
              hook[:callback].call(target, wrapped)
              next if called

              force_continuation(hook, wrapped)
            end
          end
        end

        # Observing links: an outer hook raising must not prevent inner hooks
        # and the core from running (nor may a hook cancel the work by not
        # yielding — forced continuation, with a warning). A link classifies
        # only its OWN error. One that merely passed through it on the way up
        # belongs to whoever raised it — safe: describes hook-error policy, and
        # the work's errors were never the hook engine's to judge.
        def build_safe(hooks, target, core)
          hooks.reverse.inject(classifying(core, target)) do |next_link, hook|
            safe_link(next_link, hook, target)
          end
        end

        # One observing link. `called` and `error_from_below` are per-invocation
        # state, so they live inside the returned lambda, not beside it.
        def safe_link(next_link, hook, target)
          lambda do
            called = false
            error_from_below = nil
            # Every descent runs through here, so no site below can forget to
            # mark. Identity, not class: a hook that raises its own error after
            # a successful perform.call still owns that error.
            wrapped = lambda do
              called = true
              next_link.call
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
            # A swallowed pre-yield error lands here with the work still
            # undone — a swallow must not cancel downstream.
            wrapped.call unless called
          end
        end

        # The classification boundary, seeded beneath every link so that it
        # exists with no hooks registered at all. Its absence was what let a
        # shutdown_on error escape unescalated and report :crash rather than
        # :unhealthy, purely because nobody happened to be listening. Never
        # swallows: whether an error is fatal is a property of (error, worker).
        def classifying(core, target)
          lambda do
            core.call
          rescue StandardError
            Hooks.classify_hook_error(target, safe: false)
          end
        end

        # The chain always descends, so a hook that returned without yielding
        # gets its continuation run anyway. Shared by both builders — the rule
        # doesn't vary with the error policy.
        def force_continuation(hook, wrapped)
          log_forgotten_yield(hook[:callback])
          wrapped.call
        end

        # Warn when an around-hook returned without yielding (calling perform).
        # Both chain builders force-run the continuation regardless — the chain
        # always descends, and a hook that wants to short-circuit resolves the
        # job instead — but the operator should know a hook is misbehaving.
        # Includes the hook's source location.
        def log_forgotten_yield(callback)
          location = callback.source_location&.join(":")
          suffix = location ? " (at #{location})" : ""
          Busybee.logger&.warn(
            "[busybee] Observing around-hook returned without yielding; " \
            "forcing continuation#{suffix}"
          )
        end
      end
    end
  end
end
