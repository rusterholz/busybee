# frozen_string_literal: true

require "busybee/client/call"
require "busybee/hooks"
require "busybee/job"
require "busybee/testing/hook_registry"
require "busybee/testing/runner"
require "busybee/worker/status"

module Busybee
  module Testing
    module Helpers
      # Fires one hook moment against a carrier you built: every registered hook
      # of that type whose filters accept the carrier runs, as busybee would run
      # it there. So a spec asks "when this job fails, what does my code do?" and
      # gets the wiring and the hook body in one answer.
      #
      # @example Does a failed job reach my metrics?
      #   fire_busybee_hooks(:on_job_executed, build_test_job(type: "ship_order", status: :failed))
      #   expect(Metrics.count("jobs.failed")).to eq(1)
      module HookFiring
        CARRIERS = { job: Busybee::Job, worker: Busybee::Worker::Status, call: Busybee::Client::Call }.freeze
        PERFORM_TYPES = %i[before_perform around_perform after_perform].freeze
        AROUND_TYPES = %i[around_perform around_job_execution around_call].freeze

        # Errors a hook raises propagate. Respects without_busybee_hooks, but raises
        # rather than run nothing when it has suppressed the whole moment.
        #
        # @param type [Symbol] the hook moment, e.g. :after_perform
        # @param carrier [Busybee::Job, Busybee::Worker::Status, Busybee::Client::Call,
        #   Busybee::Testing::Runner] what the moment's hooks receive; a test worker
        #   stands in for its own status
        # @yield the continuation an around hook wraps; a no-op when omitted
        # @return the carrier given
        # @raise [ArgumentError] for an unknown moment, a carrier of the wrong
        #   kind, or a moment without_busybee_hooks has silenced entirely
        def fire_busybee_hooks(type, carrier, &continuation)
          target = HookFiring.target_for(type, carrier)
          HookFiring.refuse_silenced!(type)
          HookFiring.correlating(type, target) do
            if AROUND_TYPES.include?(type)
              Hooks.run_chain(type, target) { continuation&.call }
            else
              Hooks.run(type, target)
            end
          end
          carrier
        end

        class << self
          def target_for(type, carrier)
            Hooks.hooks_for(type)
            noun = Hooks::HOOK_NOUN.fetch(type)
            carrier = carrier.status if noun == :worker && carrier.is_a?(Testing::Runner)
            return carrier if carrier.is_a?(CARRIERS.fetch(noun))

            raise ArgumentError, "#{type} hooks receive a #{CARRIERS.fetch(noun)}" \
                                 "#{' (or a test worker)' if noun == :worker}, not a #{carrier.class}"
          end

          def refuse_silenced!(type)
            return unless Hooks.hooks_for(type).empty? && HookRegistry.suppressed?(type)

            raise ArgumentError, "every #{type} hook is suppressed here by without_busybee_hooks, " \
                                 "so fire_busybee_hooks would run nothing. Fire it outside the suppression, " \
                                 "or set `without_busybee_hooks: []` on this example"
          end

          # The scopes production fires these moments in, so a call a hook makes
          # is attributed the same way.
          def correlating(type, target, &block)
            return yield unless target.is_a?(Busybee::Job)

            Client::Call.with_worker_status(target.worker_status) do
              PERFORM_TYPES.include?(type) ? Client::Call.with_job(target, &block) : yield
            end
          end
        end
      end
    end
  end
end
