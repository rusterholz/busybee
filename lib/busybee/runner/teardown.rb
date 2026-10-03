# frozen_string_literal: true

require "busybee/hooks"
require "busybee/worker/shutdown"

module Busybee
  class Runner
    # What run!'s ensure does about things that go wrong inside it. The invariant:
    # the ensure always completes, or jobs go unreturned, monitoring goes blind,
    # and @running wedges true — leaving the runner silently unable to run again.
    module Teardown
      private

      # run!'s ensure body; exception is what the run exits on, nil when clean. A
      # contained escalation reaches T3 only where no exit exception explains it.
      def teardown(exception)
        cease_intake
        error = Busybee::Worker::Shutdown.unwrap(exception)
        @stop_reason.compare_and_set(nil, reason_for(exception)) if exception
        fire_worker_lifecycle(:stopping_at, :on_worker_stopping, error)
        drain_within_teardown(exception)
        fire_worker_lifecycle(:shutdown_at, :on_worker_shutdown, error || @teardown_error.get)
        @running.make_false
      end

      # Stamp a closing moment (T2/T3) and fire its observation-only hook with a
      # fresh Status. error is the classified in-flight exception, shared by both.
      def fire_worker_lifecycle(stamp, type, error)
        @worker_timestamps.stamp!(stamp)
        contain_teardown_escalation(type) { Hooks.run(type, worker_status(error: error), safe: true) }
      end

      # The ensure's other door: a failing wire call, or the pump join re-raising
      # what killed the pump, would skip the rest as an escalating hook used to.
      # Skipped outright on a non-recoverable exit, whose calls are about to fail.
      def drain_within_teardown(exception)
        return if exception && !recoverable?(exception)

        drain_on_shutdown
      rescue *RECOVERABLE_ERRORS => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Drain failed during shutdown, continuing teardown: " \
                              "[#{e.class}] #{e.message}")
      end

      def recoverable?(error) = RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      # A worker already tearing down cannot shut down harder, so escalation buys
      # nothing at T1/T2/T3 while costing the drain, the later moments, and the
      # exception it was exiting on. T0 is excluded by not being wrapped.
      def contain_teardown_escalation(type)
        yield
      rescue Busybee::Worker::Shutdown => e
        @teardown_error.compare_and_set(nil, e)
        Busybee.logger&.error("[busybee] Shutdown from #{type} ignored, already shutting down: " \
                              "[#{e.class}] #{e.message}")
      end
    end
  end
end
