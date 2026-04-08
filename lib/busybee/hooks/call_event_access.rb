# frozen_string_literal: true

require "busybee/hooks/event_access"

module Busybee
  module Hooks
    # Call-specific event access mixin. Will provide call result predicates
    # (success?, errored?), duration_ms, and tags.
    #
    # Implementation deferred to Mission 7b.
    module CallEventAccess
      include EventAccess
    end
  end
end
