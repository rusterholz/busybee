# frozen_string_literal: true

module Logistics
  class PlanShipmentsWorker < Busybee::Worker
    description "Plans optimal shipment groupings to minimize shipment count and delivery distance"

    variable :warehouses, description: "Array of {id, distance, address: {lat, lon}}"
    variable :items,      description: "Array of {type, qty, available_at: [warehouse_ids]}"

    output :planned_shipments, description: "Array of {warehouse_id, warehouse_address, items}"

    def perform
      plan = nil
      (1..warehouse_list.size).each do |size|
        plan ||= best_plan_for_size(size)
      end

      raise "Unable to plan shipments!" if plan.nil?

      { planned_shipments: plan }
    end

    private

    def warehouse_list
      @warehouse_list ||= warehouses.sort_by { |w| w["distance"] }
    end

    def item_list
      @item_list ||= items.map { |i| i.transform_keys(&:to_s) }
    end

    def best_plan_for_size(size)
      best_plan = nil
      best_score = Float::INFINITY

      warehouse_list.combination(size).each do |combo|
        next unless covers_all_items?(combo)

        assignment = assign_items_to_warehouses(combo)
        score = score_assignment(combo, assignment)

        if score < best_score # lower is better
          best_score = score
          best_plan = build_plan(combo, assignment)
        end
      end

      best_plan
    end

    def covers_all_items?(combo)
      combo_ids = combo.to_set { |w| w["id"] }
      item_list.all? do |item|
        available = item["available_at"] || []
        available.any? { |wid| combo_ids.include?(wid) }
      end
    end

    def assign_items_to_warehouses(combo)
      Hash.new { |h, k| h[k] = [] }.tap do |assignment|
        item_list.each do |item|
          best_wh = find_best_warehouse_for(item, combo)
          assignment[best_wh["id"]] << item if best_wh
        end
      end
    end

    def find_best_warehouse_for(item, combo)
      combo.
        select { |w| item["available_at"]&.include?(w["id"]) }.
        min_by { |w| w["distance"] }
    end

    def score_assignment(combo, assignment)
      wh_by_id = combo.index_by { |w| w["id"] }
      assignment.sum do |wh_id, assigned_items|
        dist = wh_by_id[wh_id]["distance"]
        assigned_items.sum { |item| dist * (item["qty"] || 1) }
      end
    end

    def build_plan(combo, assignment)
      wh_by_id = combo.index_by { |w| w["id"] }
      assignment.map do |wh_id, assigned_items|
        wh = wh_by_id[wh_id]
        {
          warehouse_id: wh_id,
          warehouse_address: wh["address"],
          items: assigned_items.map { |i| { type: i["type"], qty: i["qty"] || 1 } }
        }
      end
    end
  end
end
