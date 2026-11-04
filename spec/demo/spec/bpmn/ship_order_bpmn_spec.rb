# frozen_string_literal: true

RSpec.describe "ship_order BPMN", :zeebe do
  let(:test_variables) do
    {
      order: { id: "order-#{SecureRandom.hex(4)}" }
    }
  end

  let(:mock_shipments) do
    [
      { id: "ship-1", item_count: 3 },
      { id: "ship-2", item_count: 1 }
    ]
  end

  it "activates load_order_shipments as the first step" do
    with_process_instance("ship_order", test_variables) do
      job = activate_job("load_order_shipments")
      expect(job.variables["order_id"]).to eq(test_variables[:order][:id])
    end
  end

  it "activates simulate_pick_and_pack for each shipment in the multi-instance" do
    with_process_instance("ship_order", test_variables) do
      activate_job("load_order_shipments").
        and_complete(shipments: mock_shipments)

      jobs = activate_jobs("simulate_pick_and_pack", expected: 2)
      expect { activate_job("simulate_pick_and_pack", timeout: 1_000) }.not_to have_available_jobs

      item_counts = jobs.map { |j| j.variables["item_count"] }.sort
      expect(item_counts).to eq([1, 3])

      shipment_ids = jobs.map { |j| j.variables["shipment_id"] }.sort
      expect(shipment_ids).to eq(%w[ship-1 ship-2])
    end
  end

  it "activates update_shipment_status (packed) after pick-and-pack for each shipment" do
    with_process_instance("ship_order", test_variables) do
      activate_job("load_order_shipments").and_complete(shipments: mock_shipments)

      # Complete all pick-and-pack jobs
      activate_jobs("simulate_pick_and_pack", expected: 2).each(&:mark_completed)

      # update_shipment_status (packed) should activate for each shipment
      pack_jobs = activate_jobs("update_shipment_status", expected: 2)
      expect { activate_job("update_shipment_status", timeout: 1_000) }.not_to have_available_jobs

      shipment_ids = pack_jobs.map { |j| j.variables["shipment_id"] }.sort
      expect(shipment_ids).to eq(%w[ship-1 ship-2])
    end
  end

  it "activates update_order_status (packed) after all shipments are packed" do
    with_process_instance("ship_order", test_variables) do
      activate_job("load_order_shipments").and_complete(shipments: mock_shipments)

      activate_jobs("simulate_pick_and_pack", expected: 2).each(&:mark_completed)

      activate_jobs("update_shipment_status", expected: 2).each(&:mark_completed)

      # update_order_status should activate after all subprocess instances complete
      job = activate_job("update_order_status")
      expect(job.variables["order_id"]).to eq(test_variables[:order][:id])

      job.mark_completed
      assert_process_completed!
    end
  end
end
