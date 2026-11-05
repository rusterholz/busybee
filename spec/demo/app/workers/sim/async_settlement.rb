# frozen_string_literal: true

require "concurrent"

module Sim
  # busybee hands back unworked jobs itself when a worker stops. This exists only
  # because these workers settle asynchronously: once perform dispatches a job to
  # the worker's own future, busybee counts it executed and neither tracks, waits
  # for, nor hands it back, so a stop leaves it locked until its deadline unless
  # the worker returns it (limits in full: docs/internal.md, Asynchronous Settlement).
  # Dispatched jobs sit in a per-class registry; settling claims the entry first,
  # so a future finishing mid-stop and the on_worker_stopping handback never both
  # reach the engine. A handback keeps the job's retries, as busybee's own does.
  module AsyncSettlement
    extend ActiveSupport::Concern

    included { @in_flight = Concurrent::Map.new }

    class_methods do
      attr_reader :in_flight

      def hand_back_in_flight_jobs
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

    def settle
      yield if self.class.in_flight.delete(job.key)
    end
  end
end
