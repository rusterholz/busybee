# frozen_string_literal: true

module Busybee
  module Hooks
    # Builds the nested lambda chain used by Hooks.run_around_chain.
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
            rescue Busybee::Worker::Shutdown
              raise
            rescue StandardError => e
              Hooks.log_swallowed_error(e)
              next_link.call unless called
            end
          end
        end
      end
    end
  end
end
