# frozen_string_literal: true

RSpec.describe "deliver_shipment BPMN", :zeebe do
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

  # Complete the happy path up to assign_driver (both parallel branches start)
  def complete_branch_a(assign_driver_result: { driver_id: "drv-1", driver_name: "Test Driver",
                                                request_id: "req-1" })
    activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)
    activate_job("assign_driver").and_complete(assign_driver_result)
    sleep(0.3)
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
      complete_branch_a

      calc_job = activate_job("calculate_distance")
      # from_lat/lon should come from shipment.warehouse.address
      expect(calc_job.variables["from_lat"]).to eq(-6.0)
      expect(calc_job.variables["from_lon"]).to eq(5.0)
      # to_lat/lon should come from destination (set by load_order_address output mapping)
      expect(calc_job.variables["to_lat"]).to eq(5.3)
      expect(calc_job.variables["to_lon"]).to eq(-2.1)
    end
  end

  it "activates update_shipment_status (in_transit) after parallel join" do
    with_process_instance("deliver_shipment", test_variables) do
      complete_branch_a

      activate_job("calculate_distance").and_complete(distance: 12.45)
      sleep(0.3)

      transit_job = activate_job("update_shipment_status")
      expect(transit_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
    end
  end

  it "activates simulate_delivery_run after update_shipment_status (in_transit)" do
    with_process_instance("deliver_shipment", test_variables) do
      complete_branch_a

      activate_job("calculate_distance").and_complete(distance: 12.45)
      sleep(0.3)

      activate_job("update_shipment_status").and_complete
      sleep(0.3)

      delivery_job = activate_job("simulate_delivery_run")
      expect(delivery_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
      expect(delivery_job.variables["distance"]).to eq(12.45)
    end
  end

  it "activates update_shipment_status (delivered) and complete_driver_delivery in parallel after delivery" do
    with_process_instance("deliver_shipment", test_variables) do
      complete_branch_a

      activate_job("calculate_distance").and_complete(distance: 12.45)
      sleep(0.3)
      activate_job("update_shipment_status").and_complete
      sleep(0.3)
      activate_job("simulate_delivery_run").and_complete
      sleep(0.3)

      # Both should activate from the second parallel split
      delivered_job = activate_job("update_shipment_status")
      expect(delivered_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
      expect(delivered_job.variables["order_id"]).to eq(test_variables[:shipment][:order_id])

      driver_job = activate_job("complete_driver_delivery")
      expect(driver_job.variables["driver_id"]).to eq("drv-1")
      expect(driver_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
      expect(driver_job.variables["distance"]).to eq(12.45)
    end
  end

  context "when all shipments are delivered" do
    it "activates update_order_status (fulfilled) via the exclusive gateway" do
      with_process_instance("deliver_shipment", test_variables) do
        complete_branch_a

        activate_job("calculate_distance").and_complete(distance: 12.45)
        sleep(0.3)
        activate_job("update_shipment_status").and_complete
        sleep(0.3)
        activate_job("simulate_delivery_run").and_complete
        sleep(0.3)

        # Mark as all delivered
        activate_job("update_shipment_status").and_complete(all_delivered: true)
        activate_job("complete_driver_delivery").and_complete
        sleep(0.3)

        # update_order_status (fulfilled) should activate
        fulfill_job = activate_job("update_order_status")
        expect(fulfill_job.variables["order_id"]).to eq(test_variables[:shipment][:order_id])

        fulfill_job.mark_completed
        assert_process_completed!
      end
    end
  end

  context "when not all shipments are delivered" do
    it "skips update_order_status (fulfilled) and completes the process" do
      with_process_instance("deliver_shipment", test_variables) do
        complete_branch_a

        activate_job("calculate_distance").and_complete(distance: 12.45)
        sleep(0.3)
        activate_job("update_shipment_status").and_complete
        sleep(0.3)
        activate_job("simulate_delivery_run").and_complete
        sleep(0.3)

        # Mark as NOT all delivered
        activate_job("update_shipment_status").and_complete(all_delivered: false)
        activate_job("complete_driver_delivery").and_complete
        sleep(0.3)

        # update_order_status should NOT activate - process should complete without it
        expect { activate_job("update_order_status") }.
          to raise_error(Busybee::Testing::NoJobAvailable)

        assert_process_completed!
      end
    end
  end

  context "when no driver is immediately available" do
    it "waits for a driver_available message then continues the process" do
      with_process_instance("deliver_shipment", test_variables) do
        request_id = "req-#{SecureRandom.hex(4)}"

        # Branch A proceeds normally
        activate_job("load_order_address").and_complete(lat: 5.3, lon: -2.1)

        # Branch B: no driver available — returns nil driver info with request_id
        activate_job("assign_driver").and_complete(
          driver_id: nil, driver_name: nil, request_id: request_id
        )
        sleep(0.3)

        # Branch A continues independently
        activate_job("calculate_distance").and_complete(distance: 12.45)
        sleep(0.3)

        # Parallel join should NOT fire yet — branch B is waiting for a driver
        expect { activate_job("update_shipment_status") }.
          to raise_error(Busybee::Testing::NoJobAvailable)

        # A driver becomes available — publish the correlation message
        publish_message("driver_available",
                        correlation_key: request_id,
                        variables: { driver_id: "drv-late", driver_name: "Late Driver" })
        sleep(0.5)

        # Parallel join fires — process continues with the late driver's info
        transit_job = activate_job("update_shipment_status")
        expect(transit_job.variables["shipment_id"]).to eq(test_variables[:shipment][:id])
      end
    end
  end
end
