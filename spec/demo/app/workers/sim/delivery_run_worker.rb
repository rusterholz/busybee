# frozen_string_literal: true

require "concurrent"

module Sim
  # Non-blocking: runs delays in background Futures so a single worker thread can
  # handle all deliveries concurrently. The semaphore (lazy-loaded to avoid querying
  # Driver.count before seeds run) limits concurrency to the actual number of drivers.
  # New drivers recruited by AssignDriverWorker are detected automatically — the
  # semaphore gains permits to match. The 5-minute job_timeout covers semaphore wait
  # time; update_timeout tightens the deadline once a driver is acquired.
  #
  # TODO: Revert this to a blocking worker to showcase busybee's native thread pool
  # feature.
  class DeliveryRunWorker < Busybee::Worker
    job_type "simulate_delivery_run"
    description "Simulates a driver's delivery trip with distance-proportional delays"
    complete_job_on_success false
    job_timeout 5.minutes

    variable :distance, type: :decimal, description: "Distance to travel in grid units"

    BASE_DELAY = 1.5 # seconds per distance unit
    @semaphore_mutex = Mutex.new

    def self.drivers_semaphore
      @semaphore_mutex.synchronize do
        current_count = Delivery::Driver.count
        @drivers_semaphore ||= Concurrent::Semaphore.new(current_count).tap { @known_driver_count = current_count }

        if current_count > @known_driver_count
          (current_count - @known_driver_count).times { @drivers_semaphore.release }
          @known_driver_count = current_count
        end

        @drivers_semaphore
      end
    end

    def perform
      delay = calculate_delay
      semaphore = self.class.drivers_semaphore

      Rails.logger.info("Queued delivery run, #{distance} units " \
                        "(#{delay.round(1)}s delay, #{semaphore.available_permits}/" \
                        "#{Delivery::Driver.count} drivers free)")

      Concurrent::Promises.
        future { run_delivery(semaphore, delay) }.
        then { on_delivery_done(delay) }.
        rescue { |err| on_delivery_error(err) }
    end

    private

    def calculate_delay
      speed = Rails.application.config.x.demo.simulation_speed
      jitter = 0.8 + (rand * 0.4)
      distance.to_f * BASE_DELAY * jitter / speed
    end

    def run_delivery(semaphore, delay)
      semaphore.acquire
      update_timeout((delay.ceil + 2).seconds)
      Rails.logger.info("Driver en route, #{distance} units (#{delay.round(1)}s)...")
      sleep(delay)
    ensure
      semaphore.release
    end

    def on_delivery_done(delay)
      Rails.logger.info("Driver arrived after #{delay.round(1)}s")
      complete!
    end

    def on_delivery_error(error)
      Rails.logger.error("Delivery run failed: #{error.message}")
      fail!(error.message)
    end
  end
end
