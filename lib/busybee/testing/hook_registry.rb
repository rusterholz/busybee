# frozen_string_literal: true

require "busybee/hooks"

module Busybee
  module Testing
    # Snapshots, swaps and restores Hooks' registry so a spec can scope which hooks
    # fire. The registry swap is the whole mechanism: Hooks.run never checks for
    # it, and a suppressed type simply finds nothing to match. This is the only
    # code that reaches Hooks' private registry accessor; the helpers built on it
    # are without_hooks, with_isolated_hooks, fire_hooks and the builders.
    module HookRegistry
      class << self
        # Run a block and put the registry back afterwards, discarding whatever
        # was registered inside it.
        def isolated
          saved = registry.transform_values(&:dup)
          yield
        ensure
          self.registry = saved
        end

        # Run a block with only the named types able to fire; naming none
        # suppresses everything. Types are validated before anything is
        # suppressed, so a typo raises rather than silently muting the lot.
        def with_only(*types)
          types.each { |type| Hooks.hooks_for(type) }
          outer = suppressed
          begin
            @suppressed = (outer | (Hooks::HOOK_TYPES - types)).freeze
            isolated do
              kept = registry
              self.registry = Hooks::HOOK_TYPES.to_h { |type| [type, types.include?(type) ? kept[type] : []] }
              yield
            end
          ensure
            @suppressed = outer
          end
        end

        # True while a with_only leaves this type out, so a caller can tell an
        # emptied registry from one that was never registered.
        def suppressed?(type) = suppressed.include?(type)

        private

        def suppressed = @suppressed || []
        def registry = Hooks.send(:registry)

        def registry=(value)
          Hooks.send(:registry=, value)
        end
      end
    end
  end
end
