# frozen_string_literal: true

module Busybee
  module Hooks
    # Builds the nested lambda chain used by Hooks.run_chain.
    # Each hook receives (target, perform); calling perform descends one
    # step. The core block sits at the chain's center.
    #
    # In :safe mode (used by around_job_execution and other observation
    # contexts), an outer hook raising must not prevent inner hooks and the
    # core from running. Errors are logged and downstream execution continues
    # via the called-flag pattern. Shutdown errors always propagate.
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

        def build_propagating(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            -> { hook[:callback].call(target, next_link) }
          end
        end

        def build_safe(hooks, target, core)
          hooks.reverse.inject(core) do |next_link, hook|
            lambda do
              called = false
              wrapped = lambda {
                called = true
                next_link.call
              }
              hook[:callback].call(target, wrapped)
              # Clean return without yielding: an observing middleware must not
              # be able to silently cancel the wrapped work, so force the
              # continuation and warn. This sits on the normal-return path (not
              # an ensure) so a Shutdown signal still stops the chain below.
              # Setting `called` first keeps the rescue from re-running it if the
              # forced continuation raises.
              unless called
                log_forgotten_yield(hook[:callback])
                called = true
                next_link.call
              end
            rescue Busybee::Worker::Shutdown
              raise
            rescue StandardError => e
              Hooks.log_swallowed_error(e)
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
