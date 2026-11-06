# frozen_string_literal: true

require "concurrent"

module Sim
  # These workers settle asynchronously. busybee hands back unworked jobs when a
  # worker stops, but counts a job executed once perform dispatches it to the
  # worker's own future, so it returns none of these: a stop leaves them locked
  # until their deadline unless the worker does (docs/internal.md, Asynchronous
  # Settlement). Dispatched jobs sit in a per-class registry; whichever of settling
  # and the on_worker_stopping handback claims an entry first owns the job, and a
  # future that gets its semaphore after the handback stops without a call.
  module AsyncSettlement
    extend ActiveSupport::Concern

    included { @in_flight = Concurrent::Map.new }

    class_methods do
      attr_reader :in_flight

      # A kill hands nothing back in busybee itself, so not here either.
      def hand_back_in_flight_jobs(reason: nil)
        return if reason == :kill

        in_flight.each_key do |key|
          job = in_flight.delete(key) or next
          job.fail!("Worker shutting down", retries: job.retries)
        rescue StandardError => e
          Rails.logger.warn("Failed to hand back #{job_type} job ##{key}: #{e.class}: #{e.message}")
        end
      end
    end

    private

    def track_in_flight = self.class.in_flight[job.key] = job
    def in_flight? = self.class.in_flight.key?(job.key)

    # The block runs once claimed. Completion closes the work, so its error fails
    # the job as an error in the work would.
    def settle_complete
      return unless claim

      yield if block_given?
      begin
        complete!
      rescue StandardError => e
        fail_claimed(e)
      end
    end

    def settle_fail(error) = (fail_claimed(error) if claim)
    def claim = self.class.in_flight.delete(job.key)

    def fail_claimed(error)
      fail!(error.message)
    rescue StandardError => e
      Rails.logger.warn("Failed to fail #{job.type} job ##{job.key}, will time out and retry: " \
                        "#{e.class}: #{e.message}")
    end
  end
end
