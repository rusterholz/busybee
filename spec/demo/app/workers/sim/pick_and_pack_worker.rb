# frozen_string_literal: true

module Sim
  class PickAndPackWorker < Busybee::Worker
    job_type "simulate_pick_and_pack"
    description "Simulates warehouse workers picking and packing items with realistic delays"

    variable :item_count, type: :integer, description: "Number of items to pick and pack"

    BASE_DELAY = 2.0 # seconds per item

    def perform # rubocop:disable Metrics/AbcSize
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      delay = item_count.to_f * BASE_DELAY * jitter / speed
      Rails.logger.info("Picking and packing #{item_count} items (simulating #{delay.round(1)}s delay)...")
      sleep(delay)
      Rails.logger.info("Pick and pack complete for #{item_count} items")
      # No hash return — busybee will complete the job with no output variables
    end
  end
end
