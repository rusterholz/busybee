# frozen_string_literal: true

module Sim
  class PickAndPackWorker < Busybee::Worker
    job_type "simulate_pick_and_pack"
    description "Simulates warehouse workers picking and packing items with realistic delays"

    variable :item_count, type: :integer, description: "Number of items to pick and pack"

    BASE_DELAY = 2.0 # seconds per item

    def perform
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      delay = item_count.to_f * BASE_DELAY * jitter / speed
      sleep(delay)
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
