# frozen_string_literal: true

require "busybee/hooks"

module Busybee
  class Runner
    # How a stop is claimed and announced. The set-once reason is the claim:
    # whoever sets it owns the stop, records its error, and announces it.
    module Stopping
      private

      # A won stop's effects: intake ceases *before* T1 fires (close-before-fire).
      def announce_stop
        @worker_timestamps.stamp!(:stop_requested_at)
        cease_intake
        t1 = :on_worker_stop_requested
        contain_teardown_escalation(t1) { Hooks.run(t1, worker_status, safe: true) }
      end

      # The worker declared itself down: claim the stop; a winner keeps the error to raise.
      def declare_unhealthy(error) = claim_stop(:unhealthy) { |won| record_shutdown_error(error) if won }

      # Main-thread rescues: the error is still raised if an earlier stop claimed the reason.
      def declare_unhealthy_and_keep(error) = declare_unhealthy(error) || record_shutdown_error(error)

      # Set the reason if unset; record sees the outcome before any announcement.
      def claim_stop(reason, &record)
        synchronize_claim { @stop_reason.compare_and_set(nil, reason).tap(&record) }.tap { |won| announce_stop if won }
      end

      def synchronize_claim = yield
      def record_shutdown_error(_error); end
    end
  end
end
