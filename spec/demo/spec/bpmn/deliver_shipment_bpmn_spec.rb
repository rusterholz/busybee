# frozen_string_literal: true

RSpec.describe "deliver_shipment BPMN" do
  let(:test_variables) do
    {
      shipment: {
        id: "ship-#{SecureRandom.hex(4)}",
        order_id: "order-#{SecureRandom.hex(4)}",
        warehouse: {
          id: "wh-alpha",
          address: { lat: -6.0, lon: 5.0 }
        }
      }
    }
  end

  it "activates load_order_address and assign_driver in parallel" do
    with_process_instance("deliver_shipment", test_variables) do
      # Both should activate from the parallel split
      addr_job = activate_job("load_order_address")
      expect(addr_job.variables["order_id"]).to eq(test_variables[:shipment][:order_id])

      driver_job = activate_job("assign_driver")
      expect(driver_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
    end
  end

  it "activates calculate_distance after load_order_address with correct I/O mappings" do
    with_process_instance("deliver_shipment", test_variables) do
      activate_job("load_order_address").
        and_complete(lat: 5.3, lon: -2.1)

      activate_job("assign_driver").
        and_complete(driver_id: "drv-1", driver_name: "Test Driver")

      sleep(0.3)

      calc_job = activate_job("calculate_distance")
      # from_lat/lon should come from shipment.warehouse.address
      expect(calc_job.variables["from_lat"]).to eq(-6.0)
      expect(calc_job.variables["from_lon"]).to eq(5.0)
      # to_lat/lon should come from destination (set by load_order_address output mapping)
      expect(calc_job.variables["to_lat"]).to eq(5.3)
      expect(calc_job.variables["to_lon"]).to eq(-2.1)
    end
  end

  it "activates simulate_delivery_run after parallel join with shipment distance" do
    with_process_instance("deliver_shipment", test_variables) do
      activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)
      activate_job("assign_driver").and_complete(driver_id: "drv-1", driver_name: "Test Driver")
      sleep(0.3)

      activate_job("calculate_distance").and_complete(distance: 12.45)
      sleep(0.3)

      delivery_job = activate_job("simulate_delivery_run")
      expect(delivery_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
      expect(delivery_job.variables["distance"]).to eq(12.45)
    end
  end

  it "activates mark_shipment_delivered and complete_driver_delivery in parallel after delivery" do
    with_process_instance("deliver_shipment", test_variables) do
      activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)
      activate_job("assign_driver").and_complete(driver_id: "drv-1", driver_name: "Test Driver")
      sleep(0.3)
      activate_job("calculate_distance").and_complete(distance: 12.45)
      sleep(0.3)
      activate_job("simulate_delivery_run").and_complete
      sleep(0.3)

      # Both should activate from the second parallel split
      delivered_job = activate_job("mark_shipment_delivered")
      expect(delivered_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])

      driver_job = activate_job("complete_driver_delivery")
      expect(driver_job.variables["driver_id"]).to eq("drv-1")
      expect(driver_job.variables["distance"]).to eq(12.45)
    end
  end

  context "when all shipments are delivered" do
    it "activates mark_order_fulfilled via the exclusive gateway" do
      with_process_instance("deliver_shipment", test_variables) do
        activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)
        activate_job("assign_driver").and_complete(driver_id: "drv-1", driver_name: "Test Driver")
        sleep(0.3)
        activate_job("calculate_distance").and_complete(distance: 12.45)
        sleep(0.3)
        activate_job("simulate_delivery_run").and_complete
        sleep(0.3)

        # Mark as all delivered
        activate_job("mark_shipment_delivered").and_complete(all_delivered: true)
        activate_job("complete_driver_delivery").and_complete
        sleep(0.3)

        # mark_order_fulfilled should activate
        fulfill_job = activate_job("mark_order_fulfilled")
        expect(fulfill_job.variables["order_id"]).to eq(test_variables[:shipment][:order_id])

        fulfill_job.mark_completed
        assert_process_completed!
      end
    end
  end

  context "when not all shipments are delivered" do
    it "skips mark_order_fulfilled and completes the process" do
      with_process_instance("deliver_shipment", test_variables) do
        activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)
        activate_job("assign_driver").and_complete(driver_id: "drv-1", driver_name: "Test Driver")
        sleep(0.3)
        activate_job("calculate_distance").and_complete(distance: 12.45)
        sleep(0.3)
        activate_job("simulate_delivery_run").and_complete
        sleep(0.3)

        # Mark as NOT all delivered
        activate_job("mark_shipment_delivered").and_complete(all_delivered: false)
        activate_job("complete_driver_delivery").and_complete
        sleep(0.3)

        # mark_order_fulfilled should NOT activate - process should complete without it
        expect { activate_job("mark_order_fulfilled") }.
          to raise_error(Busybee::Testing::NoJobAvailable)

        assert_process_completed!
      end
    end
  end
end
