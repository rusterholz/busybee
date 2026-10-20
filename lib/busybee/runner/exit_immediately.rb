# frozen_string_literal: true

require "concurrent"

module Busybee
  class Runner
    # Errors a graceful teardown survives; past them, raise the alarm. Client::Call's
    # namesake asks about record fidelity instead: they coincide today, widen apart.
    RECOVERABLE_ERRORS = [StandardError].freeze

    # The fire alarm, process-wide and set once by an unrecoverable error or a kill:
    # every runner then skips handbacks, drains and job hooks. The first fire's reason
    # stands (nil means :crash); preallocated, so raising it allocates nothing.
    module ExitImmediately
      EXIT_IMMEDIATELY_REASON = Concurrent::AtomicReference.new(nil)
      private_constant :EXIT_IMMEDIATELY_REASON

      def exit_immediately? = !EXIT_IMMEDIATELY_REASON.get.nil?
      def exit_immediately_reason = EXIT_IMMEDIATELY_REASON.get
      def exit_immediately!(reason: :crash) = EXIT_IMMEDIATELY_REASON.compare_and_set(nil, reason || :crash)
    end
  end
end
