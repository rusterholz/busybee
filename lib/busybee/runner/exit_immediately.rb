# frozen_string_literal: true

require "concurrent"

module Busybee
  class Runner
    # The fire alarm (the building is burning), process-wide and set once by an
    # unrecoverable error or a kill: every runner then skips handbacks, drains
    # and job hooks. Raising it flags, exiting nothing, and names the fire; the
    # first fire's reason stands, nil meaning :crash. Preallocated: raising it allocates nothing.
    module ExitImmediately
      EXIT_IMMEDIATELY_REASON = Concurrent::AtomicReference.new(nil)
      private_constant :EXIT_IMMEDIATELY_REASON

      def exit_immediately? = !EXIT_IMMEDIATELY_REASON.get.nil?
      def exit_immediately_reason = EXIT_IMMEDIATELY_REASON.get
      def exit_immediately!(reason: :crash) = EXIT_IMMEDIATELY_REASON.compare_and_set(nil, reason || :crash)
    end
  end
end
