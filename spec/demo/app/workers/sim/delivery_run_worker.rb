# frozen_string_literal: true

require "concurrent"

module Sim
  # TODO: Revert this to a blocking worker to showcase busybee's native thread pool
  # feature. Currently non-blocking via concurrent-ruby Futures as a stopgap so the
  # single-threaded worker process can handle all deliveries concurrently.
  class DeliveryRunWorker < Busybee::Worker
    job_type "simulate_delivery_run"
    description "Simulates a driver's delivery trip with distance-proportional delays"
    complete_job_on_success false
    fail_job_on_error false

    variable :distance, type: :decimal, description: "Distance to travel in grid units"

    BASE_DELAY = 1.5 # seconds per distance unit

    def self.drivers_semaphore
      @drivers_semaphore ||= Concurrent::Semaphore.new(Delivery::Driver.count)
    end

    def perform
      delay = calculate_delay
      current_job = job
      semaphore = self.class.drivers_semaphore

      Rails.logger.info("Queued delivery run, #{distance} units " \
                        "(#{delay.round(1)}s delay, #{semaphore.available_permits}/" \
                        "#{Delivery::Driver.count} drivers free)")

      Concurrent::Promises.
        future { run_delivery(semaphore, delay) }.
        then { on_delivery_done(current_job, delay) }.
        rescue { |err| on_delivery_error(current_job, err) }
    end

    private

    def calculate_delay
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      distance.to_f * BASE_DELAY * jitter / speed
    end

    def run_delivery(semaphore, delay)
      semaphore.acquire
      Rails.logger.info("Driver en route, #{distance} units (#{delay.round(1)}s)...")
      sleep(delay)
    ensure
      semaphore.release
    end

    def on_delivery_done(current_job, delay)
      Rails.logger.info("Driver arrived after #{delay.round(1)}s")
      current_job.complete!
    end

    def on_delivery_error(current_job, error)
      Rails.logger.error("Delivery run failed: #{error.message}")
      current_job.fail!(error.message)
    end
  end
end
