# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::CompleteDriverDeliveryWorker do
  # Part of this worker's contract is what it puts on the wire: it publishes a BPMN
  # message to unblock a process instance waiting for a driver. The assertion is the
  # request that reached the test client, which also checks the serialization and
  # the TTL conversion.

  let(:client) { build_test_client }

  def delivery_vars(driver, shipment_id: "ship-1", distance: 5.0)
    { driver_id: driver.id, shipment_id: shipment_id, distance: distance }
  end

  def run(variables:)
    execute_worker(described_class, job: build_test_job(type: described_class.job_type,
                                                        bpmn_process_id: "deliver-shipment",
                                                        variables: variables, client: client))
  end

  def published = client.received(:publish_message)

  def driver_available_for(request, driver)
    have_attributes(
      name: "driver_available",
      correlationKey: request.id,
      timeToLive: 30_000,
      variables: JSON.generate("driver_id" => driver.id, "driver_name" => driver.name)
    )
  end

  it "adds mileage and clears the shipment assignment" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")

    job = run(variables: delivery_vars(driver, distance: 12.5))

    expect(job).not_to be_failed
    driver.reload
    expect(driver.total_mileage).to eq(62.5)
    expect(driver.current_shipment_id).to be_nil
  end

  it "claims the oldest open request and publishes a driver_available message" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")
    older = Delivery::DriverRequest.create!(shipment_id: "ship-waiting-1", requested_at: 2.minutes.ago)
    Delivery::DriverRequest.create!(shipment_id: "ship-waiting-2", requested_at: 1.minute.ago)

    job = run(variables: delivery_vars(driver))

    expect(job).not_to be_failed
    driver.reload
    expect(driver.current_shipment_id).to eq("ship-waiting-1")
    expect(older.reload.driver_id).to eq(driver.id)
    expect(published.sole).to driver_available_for(older, driver)
  end

  it "does not publish a message when no open requests exist" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")

    job = run(variables: delivery_vars(driver))

    expect(job).not_to be_failed
    expect(published).to be_empty
    expect(driver.reload.current_shipment_id).to be_nil
  end

  context "when retried after partial completion" do
    it "skips mileage when driver already released, still fulfills open requests" do
      driver = Delivery::Driver.create!(name: "Alice", total_mileage: 62.5, current_shipment_id: nil)
      request = Delivery::DriverRequest.create!(shipment_id: "ship-waiting", requested_at: 1.minute.ago)

      job = run(variables: delivery_vars(driver, distance: 12.5))

      expect(job).not_to be_failed
      expect(driver.reload.total_mileage).to eq(62.5)
      expect(driver.current_shipment_id).to eq("ship-waiting")
      expect(request.reload.driver_id).to eq(driver.id)
      expect(published.sole).to driver_available_for(request, driver)
    end

    it "re-publishes message when driver already reassigned to a claimed request" do
      driver = Delivery::Driver.create!(name: "Alice", total_mileage: 62.5,
                                        current_shipment_id: "ship-waiting")
      request = Delivery::DriverRequest.create!(shipment_id: "ship-waiting", driver_id: driver.id,
                                                requested_at: 1.minute.ago)

      job = run(variables: delivery_vars(driver, distance: 12.5))

      expect(job).not_to be_failed
      expect(driver.reload.total_mileage).to eq(62.5)
      expect(published.sole).to driver_available_for(request, driver)
    end
  end
end
