# frozen_string_literal: true

module Sim
  # The shadow orchestrator's roll decision: a per-job coin flip whose hazard
  # climbs with the worker's uptime and scales with simulation speed —
  # modelling a deploy/rollout cadence (older pods get recycled; a faster-running
  # sim rolls proportionally more often). `random` and `speed` are injectable so
  # the model is unit-testable despite being random in production.
  class RolloverPolicy
    BASE_HAZARD = 0.02  # per-job roll chance for a brand-new worker at speed 1.0
    UPTIME_SCALE = 60.0 # seconds of uptime over which the hazard roughly doubles

    class << self
      def roll?(worker_status, speed: default_speed, random: rand)
        random < hazard(worker_status, speed)
      end

      # Per-job roll probability, capped at certainty.
      def hazard(worker_status, speed)
        uptime = worker_status&.uptime_s || 0.0
        [BASE_HAZARD * (1 + (uptime / UPTIME_SCALE)) * speed, 1.0].min
      end

      # The hazard at the current sim speed — for logging the p that fired a roll.
      def hazard_for(worker_status) = hazard(worker_status, default_speed)

      private

      def default_speed = Rails.application.config.x.demo.simulation_speed
    end
  end
end
