# frozen_string_literal: true

module Logistics
  class LoadWarehousesWorker < Busybee::Worker
    description "Loads all warehouses with their coordinates for distance calculation"

    output :warehouses, description: "Array of {id, name, address: {lat, lon}}"

    def perform
      wh = Warehouse.all
      Rails.logger.info("Loaded #{wh.size} warehouses for distance calculation")
      { warehouses: wh.map(&:as_json) }
    end
  end
end
