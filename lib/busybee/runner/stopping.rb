# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require "busybee/durations"
require "busybee/grpc/error"
require "busybee/hooks"
require "busybee/logging"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # How a stop is claimed, announced and given its reason. The set-once reason
    # is the claim: its setter owns the stop, records its error in the exit slot
    # (a loser's goes to the post-stop slot) and announces it. reason_for,
    # recoverable? and the fire alarm decide the reason; last, the fetch loops'
    # gRPC policy: claim the stop, or wait out backpressure_delay unless announced.
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

      # Discern a stop reason from an exit error, never fabricated. reason ⊥ error:
      # this names the trigger, the exception rides its own axis. gateway_* groups the
      # engine-driven endings as a filterable family, like sig*.
      def reason_for(error)
        case error
        when Busybee::Worker::Shutdown then :unhealthy
        when Busybee::GRPC::Error then :gateway_error
        else :crash
        end
      end

      def recoverable?(error) = RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      # Claim the stop for an error. A won claim caused the stop: its error is the
      # exit error, raised at loop exit, recorded before the announcement wakes
      # anyone. A lost one met a stop under way: a post-stop error, never raised,
      # reported at T3 and logged, unless it is the exit error already (a re-raised
      # claim). Both effects run after the lock is released.
      def claim_stop(reason, error) # rubocop:disable Naming/PredicateMethod
        outcome = synchronize_claim do
          if @stop_reason.compare_and_set(nil, reason)
            record_shutdown_error(error)
            :won
          elsif record_post_stop_error(error)
            :post_stop
          end
        end
        announce_stop if outcome == :won
        log_post_stop_error(error) if outcome == :post_stop
        outcome == :won
      end

      # The first is kept for T3; each new one is logged. An error claimed twice
      # in a row (an activation's escalation, then the loop it ends) counts once.
      def record_post_stop_error(error)
        return false if @shutdown_error.equal?(error) || @last_post_stop_error.equal?(error)

        @post_stop_error ||= error
        @last_post_stop_error = error
      end

      # The process may be out of memory, so an unrecoverable error's line takes
      # no status snapshot.
      def log_post_stop_error(error)
        stopping = "after #{logged_worker_name} began stopping (#{@stop_reason.get})"
        if recoverable?(error)
          Logging.warn("Error #{stopping}, finishing the stop", worker_status, error: error)
        else
          Logging.error("Unrecoverable error #{stopping}, exiting immediately",
                        error: error, worker_class: logged_worker_name, reason: @stop_reason.get)
        end
      end

      # The exit and post-stop slots are plain ivars, read and written only inside this.
      def synchronize_claim
        # Subclasses may lock here; the base doesn't, since only its main thread claims.
        yield
      end

      def record_shutdown_error(error) = (@shutdown_error = error if @shutdown_error.nil?)
      def post_stop_error = synchronize_claim { @post_stop_error }

      # Raised once the loop has seen the stop; the claim's lock waits out a
      # record still landing behind it.
      def raise_exit_error
        error = synchronize_claim { @shutdown_error }
        raise error if error
      end

      # The fire alarm (ExitImmediately) is the class's; raising it claims no runner's stop.
      delegate :exit_immediately?, :exit_immediately!, :exit_immediately_reason, to: :class, private: true

      # The reason a runner claims for its own stop on the way out: the fire's,
      # once the process must exit immediately.
      def ending_reason(otherwise: nil) = exit_immediately_reason || otherwise

      # The fetch loops' policy for a wrapped gRPC error, matched by grpc_status
      # whatever class the gateway raised: backpressure backs off so the loop
      # retries; anything else claims the stop, raised if the claim wins.
      def handle_grpc_error(error)
        unless Busybee.backpressure_statuses.include?(error.grpc_status)
          raise error if claim_stop(:gateway_error, error)

          return
        end

        @backpressure_count.increment
        back_off(Busybee::Durations.seconds_from(@runtime_config.backpressure_delay))
      end

      # Waits out backpressure, cut short by a stop's announcement.
      def back_off(seconds) = @stop_announced.wait(seconds)
    end
  end
end
