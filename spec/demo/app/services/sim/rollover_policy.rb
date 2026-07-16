# frozen_string_literal: true

module Sim
  # The shadow orchestrator's roll decision: a hazard *rate* sampled at job
  # boundaries. Each check converts the time since this container's previous
  # check into a roll probability, so cadence tracks wall-clock (about one
  # roll per BASE_ROLL_SECONDS at speed 1.0, any throughput) instead of job
  # count — a busy container checks often over tiny slices, a quiet one
  # rarely over wide ones, and the expected rolls per minute come out equal.
  # The rate climbs with the worker's uptime (older incarnations get recycled
  # first) and scales with simulation speed. `random`/`speed`/`now` are
  # injectable so the model is unit-testable despite being random in production.
  class RolloverPolicy
    BASE_ROLL_SECONDS = 240.0 # mean seconds between rolls for a fresh container at speed 1.0
    UPTIME_SCALE = 180.0      # uptime over which the rate roughly doubles (ages the observed mean down)

    @last_checked = Concurrent::AtomicReference.new

    class << self
      # Evaluate the hazard over the elapsed slice; returns the probability
      # that fired (for logging) or nil. Consumes the slice either way — the
      # next check starts fresh.
      def roll(worker_status, speed: default_speed, random: rand, now: monotonic_now)
        p = hazard(worker_status, speed, interval(now))
        p if random < p
      end

      # Roll probability over an elapsed-seconds slice, capped at certainty.
      def hazard(worker_status, speed, elapsed)
        uptime = worker_status&.uptime_s || 0.0
        rate = (1 + (uptime / UPTIME_SCALE)) / BASE_ROLL_SECONDS
        [rate * speed * elapsed, 1.0].min
      end

      # Forget the current slice (test isolation).
      def reset! = @last_checked.set(nil)

      private

      # Seconds since the previous check. The first check ever is a zero-width
      # slice: a brand-new container never rolls on its first job.
      def interval(now)
        previous = @last_checked.get_and_set(now)
        previous ? now - previous : 0.0
      end

      def default_speed = Rails.application.config.x.demo.simulation_speed
      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
