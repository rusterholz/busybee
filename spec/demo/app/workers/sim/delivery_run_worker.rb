# frozen_string_literal: true

module Sim
  class DeliveryRunWorker < Busybee::Worker
    job_type "simulate_delivery_run"
    description "Simulates a driver's delivery trip with distance-proportional delays"

    variable :distance, type: :decimal, description: "Distance to travel in grid units"

    BASE_DELAY = 1.5 # seconds per distance unit

    def perform
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      delay = distance.to_f * BASE_DELAY * jitter / speed
      sleep(delay)
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
