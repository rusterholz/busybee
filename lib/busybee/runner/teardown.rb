# frozen_string_literal: true

require "busybee/durations"
require "busybee/hooks"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # What run!'s ensure does about things that go wrong inside it. The invariant:
    # the ensure always completes, or jobs go unreturned, monitoring goes blind,
    # and @running wedges true, leaving the runner silently unable to run again.
    module Teardown
      private

      # run!'s ensure body; exception is what the run exits on, nil when clean. T3
      # reports, where no exit exception explains the shutdown, a post-stop error and
      # then a contained escalation.
      def teardown(exception)
        begin_teardown(exception)
        error = Busybee::Worker::Shutdown.unwrap(exception)
        fire_worker_lifecycle(:stopping_at, :on_worker_stopping, error)
        drain_within_teardown
        error ||= Busybee::Worker::Shutdown.unwrap(post_stop_error) || @teardown_error.get
        fire_worker_lifecycle(:shutdown_at, :on_worker_shutdown, error)
        @running.make_false
      end

      # Claim for the exit exception before intake closes, or the stream reader's
      # clean-close claim could take the reason; announce unless something already
      # has; let that announcement finish, so T1 precedes T2.
      def begin_teardown(exception)
        exit_immediately! if exception && !recoverable?(exception) # its wire calls are the ones about to fail
        @stop_reason.compare_and_set(nil, reason_for(exception)) if exception
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
      # immediately; an unrecoverable error inside it says so, unlogged, and
      # abandons the rest.
      def drain_within_teardown
        return if exit_immediately?

        drain_on_shutdown
      rescue *RECOVERABLE_ERRORS => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Drain failed during shutdown, continuing teardown: " \
                              "[#{e.class}] #{e.message}")
      rescue Exception => e # rubocop:disable Lint/RescueException
        exit_immediately!
        @teardown_error.compare_and_set(nil, e)
      end

      def recoverable?(error) = RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      # The bound on waiting for another thread's share of the shutdown.
      def shutdown_wait_seconds
        Busybee::Durations.seconds_from(@runtime_config&.shutdown_wait_timeout || Busybee.shutdown_wait_timeout)
      end

      # Nothing a T1/T2/T3 hook raises leaves this: a worker already tearing down
      # cannot shut down harder, and an escape would cost the drain, the later
      # moments and the exit exception. What safe: true lets past is recorded for
      # T3; past StandardError it also raises the fire alarm, unlogged. T0 is
      # excluded by not being wrapped.
      def contain_teardown_hooks(type)
        yield
      rescue Busybee::Worker::Shutdown => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Shutdown from #{type} ignored, already shutting down: " \
                              "[#{e.class}] #{e.message}")
      rescue Exception => e # rubocop:disable Lint/RescueException
        exit_immediately! unless recoverable?(e)
        @teardown_error.compare_and_set(nil, e)
      end
    end
  end
end
