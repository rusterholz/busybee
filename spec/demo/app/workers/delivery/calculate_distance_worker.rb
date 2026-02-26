# frozen_string_literal: true

module Delivery
  class CalculateDistanceWorker < Busybee::Worker
    description "Calculates distance between two geographic points using a configurable algorithm"

    variable :from_lat, type: :decimal, description: "Origin latitude"
    variable :from_lon, type: :decimal, description: "Origin longitude"
    variable :to_lat,   type: :decimal, description: "Destination latitude"
    variable :to_lon,   type: :decimal, description: "Destination longitude"

    header :algorithm, type: :string, description: "Distance formula to use (e.g. pythagorean)"

    output :distance, type: :decimal, description: "Computed distance rounded to 2 decimal places"

    ALGORITHMS = { "pythagorean" => :pythagorean_distance }.freeze

    def perform
      { distance: send(algorithm_method_name).round(3) }
    end

    private

    def algorithm_method_name
      return ALGORITHMS[algorithm] if ALGORITHMS.key?(algorithm)

      raise "Unknown distance algorithm: #{algorithm.inspect}. Supported: #{ALGORITHMS.keys.join(', ')}"
    end

    def pythagorean_distance
      Math.sqrt(((to_lat.to_f - from_lat.to_f)**2) + ((to_lon.to_f - from_lon.to_f)**2))
    end
  end
end
