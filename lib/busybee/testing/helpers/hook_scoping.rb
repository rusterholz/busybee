# frozen_string_literal: true

require "busybee/hooks"
require "busybee/testing/hook_registry"

module Busybee
  module Testing
    module Helpers
      # Scopes which registered hooks fire while a block runs; hooks registered
      # inside it run, and are gone when it ends. Each word names the hooks with
      # that word in their name.
      #
      # @example A worker spec that shouldn't write monitoring rows
      #   without_busybee_hooks(:job, :worker, :call) { execute_worker(MyWorker, job: job) }
      module HookScoping
        WORDS = %i[perform job worker call all].freeze

        # @param words [Array<Symbol>] any of :perform, :job, :worker, :call, or :all
        # @return [Object] the block's value
        # @raise [ArgumentError] on an unknown word, before anything is suppressed
        def without_busybee_hooks(*words, &)
          unknown = words - WORDS
          if unknown.any?
            raise ArgumentError, "Unknown hook word(s) #{unknown.map(&:inspect).join(', ')}. " \
                                 "Expected any of #{WORDS.map(&:inspect).join(', ')}"
          end

          HookRegistry.with_only(*Hooks::HOOK_TYPES.reject { |type| HookScoping.named_by?(type, words) }, &)
        end

        # Hooks registered inside the block are discarded when it ends.
        def isolate_busybee_hooks(&) = HookRegistry.isolated(&)

        # Kept off the example's namespace, which every helper here shares.
        def self.named_by?(type, words) = words.include?(:all) || type.to_s.split("_").intersect?(words.map(&:to_s))
      end
    end
  end
end
