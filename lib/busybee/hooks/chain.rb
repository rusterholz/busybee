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
        def build_propagating(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            -> { hook[:callback].call(target, next_link) }
          end
        end

        # Observing links: an outer hook raising must not prevent inner hooks
        # and the core from running (nor may a hook cancel the work by not
        # yielding — forced continuation, with a warning). Errors route through
        # the shared policy; `called` set first keeps a raising forced
        # continuation from being re-run by the swallow tail below.
        def build_safe(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            lambda do
              called = false
              wrapped = lambda {
                called = true
                next_link.call
              }
              Hooks.protect_allowing_shutdowns(target, safe: true) do
                hook[:callback].call(target, wrapped)
                unless called
                  log_forgotten_yield(hook[:callback])
                  called = true
                  next_link.call
                end
              end
              # A swallowed pre-yield error lands here with the work still
              # undone — a swallow must not cancel downstream.
              next_link.call unless called
            end
          end
        end

        # Warn when an observing around-hook returned without yielding (calling
        # perform). build_safe force-runs the continuation regardless — an
        # observer must not silently cancel the wrapped work — but the operator
        # should know a hook is misbehaving. Includes the hook's source location.
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
