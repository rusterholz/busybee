# frozen_string_literal: true

module Logistics
  class LoadWarehousesWorker < Busybee::Worker
    description "Loads all warehouses with their coordinates for distance calculation"

    output :warehouses, description: "Array of {id, name, address: {lat, lon}}"

    def perform
      { warehouses: Warehouse.all.map(&:as_json) }
    end
  end
end
