# frozen_string_literal: true

require "busybee/hooks"

module Busybee
  module Testing
    module Helpers
      # Narrows which registered hooks fire while a block runs. Everything fires by
      # default; each word names the hooks with that word in their name, the same
      # rule the hook names follow.
      #
      # @example A worker spec that shouldn't write monitoring rows
      #   without_hooks(:job, :worker, :call) { execute_worker(MyWorker, job: job) }
      module HookScoping
        WORDS = %i[perform job worker call all].freeze

        # @param words [Array<Symbol>] any of :perform, :job, :worker, :call, or :all
        # @return [Object] the block's value
        # @raise [ArgumentError] on an unknown word, before anything is suppressed
        def without_hooks(*words, &)
          unknown = words - WORDS
          if unknown.any?
            raise ArgumentError, "Unknown hook word(s) #{unknown.map(&:inspect).join(', ')}. " \
                                 "Expected any of #{WORDS.map(&:inspect).join(', ')}"
          end

          Hooks.with_only(*Hooks::HOOK_TYPES.reject { |type| HookScoping.named_by?(type, words) }, &)
        end

        # Kept off the example's namespace, which every helper here shares.
        def self.named_by?(type, words) = words.include?(:all) || type.to_s.split("_").intersect?(words.map(&:to_s))
      end
    end
  end
end
