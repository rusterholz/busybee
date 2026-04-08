# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/serialization"
require "busybee/hooks/restricted_access"
require "busybee/hooks/job_event_access"
require "busybee/hooks/worker_event_access"
require "busybee/hooks/call_event_access"

module Busybee
  # Central module for the hook/instrumentation system.
  # Provides event construction, and will gain hook registration,
  # storage, and invocation in subsequent missions.
  module Hooks
    NOUN_EVENT_ACCESS = {
      job: JobEventAccess,
      worker: WorkerEventAccess,
      call: CallEventAccess
    }.freeze

    # Build a hook event object for the given noun.
    #
    # Returns a HashWithIndifferentAccess extended with HashAccess (method-style
    # access), RestrictedAccess (framework keys locked), and the noun-specific
    # EventAccess mixin (predicates, durations, tags).
    #
    # @param noun [Symbol] :job, :worker, or :call
    # @param data [Hash] framework keys for the event
    # @return [ActiveSupport::HashWithIndifferentAccess]
    def self.build_event(noun, data)
      event_access = NOUN_EVENT_ACCESS.fetch(noun) do
        raise ArgumentError, "Unknown hook noun: #{noun.inspect}. Expected one of: #{NOUN_EVENT_ACCESS.keys.join(', ')}"
      end

      ActiveSupport::HashWithIndifferentAccess.new(data).
        extend(Busybee::Serialization::HashAccess).
        extend(RestrictedAccess).
        extend(event_access)
    end
  end
end
