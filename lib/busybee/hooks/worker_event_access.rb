# frozen_string_literal: true

require "busybee/hooks/event_access"

module Busybee
  module Hooks
    # Worker-specific event access mixin. Will provide worker lifecycle
    # predicates, computed durations (stop_duration_ms, lifetime_s), and tags.
    #
    # Implementation deferred to Mission 7a.
    module WorkerEventAccess
      include EventAccess
    end
  end
end
