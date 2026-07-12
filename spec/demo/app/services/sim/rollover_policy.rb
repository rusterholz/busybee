# frozen_string_literal: true

module Sim
  # The shadow orchestrator's roll decision: a hazard *rate* sampled at job
  # boundaries. Each check converts the time since this container's previous
  # check into a roll probability, so cadence tracks the clock (about one
  # roll per BASE_ROLL_SECONDS sim-seconds, any throughput) instead of job
  # count — a busy container checks often over tiny slices, a quiet one
  # rarely over wide ones, and the expected rolls per minute come out equal.
  # The rate climbs with the worker's age (older incarnations get recycled
  # first). The policy thinks entirely in sim-seconds — speed is only the
  # wall→sim conversion at the boundary — so rollover chance couples to
  # simulation speed exactly as the rest of the sim mechanics do
  # (jobs-per-rollover stays flat as speed varies).
  #
  # ...up to a point. A rollover simulates container recycling, whose recovery
  # cost (the reboot) is a fixed *wall*-clock expense that can't scale with sim
  # speed. So the wall roll rate is floored: the effective speed is capped at
  # MAX_ROLL_SPEED, guaranteeing a fresh container a mean lifetime of at least
  # MIN_ROLL_WALL_SECONDS wall-seconds however fast the sim runs. Without it,
  # past a few × real-time the roll interval collapses below the reboot time and
  # each domain thrashes (down ~half the time), starving its jobs across
  # successive rolls until they exhaust their retries. Impedance-matched below
  # the cap; wall-floored above it. `random`/`speed`/`now` are injectable so the
  # model is unit-testable despite being random in production.
  class RolloverPolicy
    BASE_ROLL_SECONDS = 240.0 # mean sim-seconds between rolls for a fresh container
    UPTIME_SCALE = 180.0      # sim-age over which the rate roughly doubles (ages the observed mean down)
    MIN_ROLL_WALL_SECONDS = 60.0 # min WALL seconds a fresh container lives before rolling, at any sim speed
    MAX_ROLL_SPEED = BASE_ROLL_SECONDS / MIN_ROLL_WALL_SECONDS # effective-speed cap; above it the rate stops climbing

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
      # Wall quantities convert to sim-seconds at the (floored) effective speed;
      # no explicit speed term survives into the formula.
      def hazard(worker_status, speed, elapsed)
        eff = [speed, MAX_ROLL_SPEED].min
        sim_age = (worker_status&.uptime_s || 0.0) * eff
        sim_elapsed = elapsed * eff
        [(1 + (sim_age / UPTIME_SCALE)) * sim_elapsed / BASE_ROLL_SECONDS, 1.0].min
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
