# frozen_string_literal: true

require "concurrent"

module Sim
  # Non-blocking: runs delays in background Futures so a single worker thread can
  # handle many concurrent pick-and-pack operations. The semaphore limits concurrency
  # to 3 simultaneous pickers. The 5-minute job_timeout covers semaphore wait time;
  # update_timeout tightens the deadline once a picker is acquired.
  class PickAndPackWorker < Busybee::Worker
    job_type "simulate_pick_and_pack"
    description "Simulates warehouse workers picking and packing items with realistic delays"
    complete_job_on_success false
    fail_job_on_error false
    job_timeout 5.minutes

    variable :item_count, type: :integer, description: "Number of items to pick and pack"

    BASE_DELAY = 1.4 # seconds per item
    PICKERS = Concurrent::Semaphore.new(3)

    def perform
      delay = calculate_delay
      current_job = job

      Rails.logger.info("Queued pick-and-pack for #{item_count} items " \
                        "(#{delay.round(1)}s delay, #{PICKERS.available_permits}/3 pickers free)")

      Concurrent::Promises.
        future { run_pick_and_pack(current_job, delay) }.
        then { on_pick_and_pack_done(current_job) }.
        rescue { |err| on_pick_and_pack_error(current_job, err) }
    end

    private

    def calculate_delay
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      item_count.to_f * BASE_DELAY * jitter / speed
    end

    def run_pick_and_pack(current_job, delay)
      PICKERS.acquire
      current_job.update_timeout((delay.ceil + 2).seconds)
      Rails.logger.info("Picker started on #{item_count} items (#{delay.round(1)}s)...")
      sleep(delay)
    ensure
      PICKERS.release
    end

    def on_pick_and_pack_done(current_job)
      Rails.logger.info("Pick and pack complete for #{item_count} items")
      current_job.complete!
    end

    def on_pick_and_pack_error(current_job, error)
      Rails.logger.error("Pick and pack failed: #{error.message}")
      current_job.fail!(error.message)
    end
  end
end
