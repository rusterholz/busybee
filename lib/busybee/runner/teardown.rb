# frozen_string_literal: true

require "busybee/durations"
require "busybee/hooks"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # What run!'s ensure does about things that go wrong inside it. The invariant:
    # short of an error the process can't recover from, the ensure completes, or
    # jobs go unreturned and monitoring goes blind. @running clears whatever happens,
    # or the runner is silently unable to run again.
    module Teardown
      private

      # run!'s ensure body; exception is what the run exits on, nil when clean. T3
      # reports, where no exit exception explains the shutdown, a post-stop error and
      # then a contained one.
      def teardown(exception)
        begin_teardown(exception)
        error = Busybee::Worker::Shutdown.unwrap(exception)
        fire_worker_lifecycle(:stopping_at, :on_worker_stopping, error)
        drain_within_teardown
        error ||= Busybee::Worker::Shutdown.unwrap(post_stop_error) || @teardown_error.get
        fire_worker_lifecycle(:shutdown_at, :on_worker_shutdown, error)
      ensure
        @running.make_false
      end

      # Claim for the exit exception, or for the fire a loop left on, before intake
      # closes, or the stream reader's clean-close claim could take the reason;
      # announce unless something already has; let that finish, so T1 precedes T2.
      def begin_teardown(exception)
        exit_immediately!(reason: reason_for(exception)) if exception && !recoverable?(exception) # its calls would fail
        @stop_reason.compare_and_set(nil, exception ? reason_for(exception) : ending_reason)
        announce_stop
        cease_intake # idempotent backstop for an announcement still under way elsewhere
        @stop_announced.wait(shutdown_wait_seconds) unless exit_immediately?
      end

      # Stamp a closing moment (T2/T3) and fire its observation-only hook with a
      # fresh Status. error is the classified in-flight exception, shared by both.
      def fire_worker_lifecycle(stamp, type, error)
        @worker_timestamps.stamp!(stamp)
        contain_teardown_hooks(type) { Hooks.run(type, worker_status(error: error), safe: true) }
      end

      # The ensure's other door: a failing wire call would skip the rest as an
      # escalating hook used to. Skipped outright once the process must exit
      # immediately; an unrecoverable error inside it says so and propagates,
      # abandoning the rest of the teardown.
      def drain_within_teardown
        return if exit_immediately?

        drain_on_shutdown
      rescue *RECOVERABLE_ERRORS => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Drain failed during shutdown, continuing teardown: " \
                              "[#{e.class}] #{e.message}")
      rescue Exception => e # rubocop:disable Lint/RescueException
        exit_immediately!(reason: reason_for(e))
        raise
      end

      def recoverable?(error) = RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      # Process-wide: read where the validating setter put it, never off a runtime config.
      def shutdown_wait_seconds = Busybee::Durations.seconds_from(Busybee.shutdown_wait_timeout)

      # A Shutdown from a T1/T2/T3 hook stays here, as does a recoverable error
      # safe: true lets past, each recorded for T3: a worker already tearing down
      # cannot shut down harder. Past RECOVERABLE_ERRORS, an error raises the fire
      # alarm and propagates, taking the rest of the teardown with it. T0 is
      # excluded by not being wrapped.
      def contain_teardown_hooks(type)
        yield
      rescue Busybee::Worker::Shutdown => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Shutdown from #{type} ignored, already shutting down: " \
                              "[#{e.class}] #{e.message}")
      rescue *RECOVERABLE_ERRORS => e
        @teardown_error.compare_and_set(nil, e)
      rescue Exception => e # rubocop:disable Lint/RescueException
        exit_immediately!(reason: reason_for(e))
        raise
      end
    end
  end
end
