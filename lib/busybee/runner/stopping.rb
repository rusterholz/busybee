# frozen_string_literal: true

require "busybee/hooks"

module Busybee
  class Runner
    # How a stop is claimed and announced. The set-once reason is the claim:
    # whoever sets it owns the stop, records its error, and announces it.
    module Stopping
      private

      # A stop's effects, once per run on whichever thread gets here first:
      # intake ceases *before* T1 fires (close-before-fire), and the teardown
      # waits on @stop_announced, so T1 also comes before T2.
      def announce_stop
        return unless @announcing.make_true

        begin
          @worker_timestamps.stamp!(:stop_requested_at)
          cease_intake
          t1 = :on_worker_stop_requested
          contain_teardown_hooks(t1) { Hooks.run(t1, worker_status, safe: true) }
        ensure
          @stop_announced.set
        end
      end

      def declare_unhealthy(error) = claim_stop(:unhealthy, error)

      # Claim the stop for an error. A won claim caused the stop: its error is the
      # exit error, raised at loop exit, recorded before the announcement wakes
      # anyone. A lost one met a stop under way: a post-stop error, never raised,
      # reported at T3, unless it is the exit error already (a re-raised claim).
      def claim_stop(reason, error)
        won = synchronize_claim do
          @stop_reason.compare_and_set(nil, reason).tap do |claimed|
            if claimed
              record_shutdown_error(error)
            elsif !@shutdown_error.equal?(error)
              @post_stop_error ||= error
            end
          end
        end
        announce_stop if won
        won
      end

      # The exit and post-stop slots are plain ivars, read and written only inside this.
      def synchronize_claim = yield
      def record_shutdown_error(error) = (@shutdown_error = error if @shutdown_error.nil?)
      def post_stop_error = synchronize_claim { @post_stop_error }

      # Raised once the loop has seen the stop; the claim's lock waits out a
      # record still landing behind it.
      def raise_exit_error
        error = synchronize_claim { @shutdown_error }
        raise error if error
      end

      # The fire alarm (the building is burning): raising it flags, exiting nothing.
      def exit_immediately! = EXIT_IMMEDIATELY.make_true
      def exit_immediately? = EXIT_IMMEDIATELY.true?
    end
  end
end
