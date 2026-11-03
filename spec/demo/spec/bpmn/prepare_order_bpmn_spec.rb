# frozen_string_literal: true

RSpec.describe "prepare_order BPMN", :zeebe do
  let(:test_variables) do
    {
      order: {
        id: "order-#{SecureRandom.hex(4)}",
        items: [
          { type: "wireless-mouse", quantity: 2 },
          { type: "usb-c-hub", quantity: 1 }
        ],
        address: { lat: 5.3, lon: -2.1 }
      },
      timeout: "PT5M"
    }
  end

  let(:mock_warehouses) do
    [
      { id: "wh-alpha", name: "Alpha", address: { lat: -6.0, lon: 5.0 } },
      { id: "wh-beta", name: "Beta", address: { lat: 5.0, lon: 7.0 } }
    ]
  end

  it "activates load_warehouses on Branch A and load_item_availability on Branch B in parallel" do
    with_process_instance("prepare_order", test_variables) do
      # Branch A: load_warehouses should activate
      activate_job("load_warehouses").
        expect_variables(order: test_variables[:order]).
        and_complete(warehouses: mock_warehouses)

      # Branch B: load_item_availability should activate for each item
      jobs = activate_jobs("load_item_availability", expected: 2)
      expect { activate_job("load_item_availability", timeout: 1_000) }.not_to have_available_jobs

      item_types = jobs.map { |j| j.variables["item_type"] }.sort
      expect(item_types).to eq(%w[usb-c-hub wireless-mouse])

      quantities = jobs.map { |j| j.variables["quantity"] }.sort
      expect(quantities).to eq([1, 2])
    end
  end

  it "activates calculate_distance for each warehouse after load_warehouses completes" do
    with_process_instance("prepare_order", test_variables) do
      activate_job("load_warehouses").
        and_complete(warehouses: mock_warehouses)

      # Complete Branch B so it doesn't block later steps
      activate_jobs("load_item_availability", expected: 2).each do |job|
        job.mark_completed(warehouse_ids: %w[wh-alpha wh-beta])
      end

      # calculate_distance should activate for each warehouse
      calc_jobs = activate_jobs("calculate_distance", expected: 2)
      expect { activate_job("calculate_distance", timeout: 1_000) }.not_to have_available_jobs

      calc_jobs.each do |job|
        expect(job.variables).to include("from_lat", "from_lon", "to_lat", "to_lon")
        expect(job.variables["to_lat"]).to eq(5.3)
        expect(job.variables["to_lon"]).to eq(-2.1)
      end
    end
  end

  it "activates plan_shipments after both parallel branches complete with correctly merged variables" do
    with_process_instance("prepare_order", test_variables) do
      # Complete Branch A: load_warehouses + calculate_distance
      activate_job("load_warehouses").and_complete(warehouses: mock_warehouses)

      # Complete Branch B: load_item_availability for all items
      activate_jobs("load_item_availability", expected: 2).each do |job|
        job.mark_completed(warehouse_ids: %w[wh-alpha wh-beta])
      end

      # Complete calculate_distance for each warehouse
      activate_jobs("calculate_distance", expected: 2).each do |job|
        job.mark_completed(distance: 7.5)
      end

      # plan_shipments should now activate with merged data
      plan_job = activate_job("plan_shipments")

      # Warehouses should be enriched with distance
      warehouses = plan_job.variables["warehouses"]
      expect(warehouses.size).to eq(2)
      warehouses.each do |wh|
        expect(wh).to include("id", "address", "distance")
        expect(wh["distance"]).to eq(7.5)
      end

      # Items should be enriched with availability
      items = plan_job.variables["items"]
      expect(items.size).to eq(2)
      items.each do |item|
        expect(item).to include("type", "quantity", "available_at")
        expect(item["available_at"]).to eq(%w[wh-alpha wh-beta])
      end
    end
  end

  it "activates create_shipment for each planned shipment" do
    with_process_instance("prepare_order", test_variables) do
      # Complete all steps up to plan_shipments
      activate_job("load_warehouses").and_complete(warehouses: mock_warehouses)
      activate_jobs("load_item_availability", expected: 2).each do |job|
        job.mark_completed(warehouse_ids: %w[wh-alpha wh-beta])
      end
      activate_jobs("calculate_distance", expected: 2).each { |j| j.mark_completed(distance: 7.5) }

      planned_shipments = [
        { warehouse_id: "wh-alpha", items: [{ type: "wireless-mouse", quantity: 2 }] },
        { warehouse_id: "wh-beta", items: [{ type: "usb-c-hub", quantity: 1 }] }
      ]

      activate_job("plan_shipments").and_complete(planned_shipments: planned_shipments)

      # create_shipment should activate for each planned shipment
      create_jobs = activate_jobs("create_shipment", expected: 2)
      expect { activate_job("create_shipment", timeout: 1_000) }.not_to have_available_jobs

      create_jobs.each do |job|
        expect(job.variables["order_id"]).to eq(test_variables[:order][:id])
        expect(job.variables).to include("warehouse_id", "items")
      end
    end
  end

  it "activates update_order_status (processing) after all shipments are created" do
    with_process_instance("prepare_order", test_variables) do
      # Complete all steps through create_shipment
      activate_job("load_warehouses").and_complete(warehouses: mock_warehouses)
      activate_jobs("load_item_availability", expected: 2).each do |job|
        job.mark_completed(warehouse_ids: %w[wh-alpha wh-beta])
      end
      activate_jobs("calculate_distance", expected: 2).each { |j| j.mark_completed(distance: 7.5) }

      planned_shipments = [
        { warehouse_id: "wh-alpha", items: [{ type: "wireless-mouse", quantity: 2 }] }
      ]
      activate_job("plan_shipments").and_complete(planned_shipments: planned_shipments)

      activate_job("create_shipment").and_complete(shipment_id: "ship-#{SecureRandom.hex(4)}", item_count: 2)

      # update_order_status should now activate
      final_job = activate_job("update_order_status")
      expect(final_job.variables["order_id"]).to eq(test_variables[:order][:id])

      final_job.mark_completed
      assert_process_completed!
    end
  end
end
