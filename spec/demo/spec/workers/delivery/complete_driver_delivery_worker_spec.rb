# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::CompleteDriverDeliveryWorker do
  # The worker uses job.instance_variable_get(:@client) to publish messages.
  # build_worker_job creates a mock client — we add publish_message to it for
  # tests that exercise request fulfillment.
  def build_job_with_message_support(variables:)
    job = build_worker_job(variables: variables)
    allow(mock_client_for(job)).to receive(:publish_message)
    job
  end

  def mock_client_for(job)
    job.instance_variable_get(:@client)
  end

  def delivery_vars(driver, shipment_id: "ship-1", distance: 5.0)
    { driver_id: driver.id, shipment_id: shipment_id, distance: distance }
  end

  it "adds mileage and clears the shipment assignment" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")

    execute_worker(described_class, variables: delivery_vars(driver, distance: 12.5))

    driver.reload
    expect(driver.total_mileage).to eq(62.5)
    expect(driver.current_shipment_id).to be_nil
  end

  it "claims the oldest open request and publishes a driver_available message" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")
    older = Delivery::DriverRequest.create!(shipment_id: "ship-waiting-1", requested_at: 2.minutes.ago)
    Delivery::DriverRequest.create!(shipment_id: "ship-waiting-2", requested_at: 1.minute.ago)

    job = build_job_with_message_support(variables: delivery_vars(driver))
    described_class.perform_job(job)
    expect(job).not_to be_failed

    driver.reload
    expect(driver.current_shipment_id).to eq("ship-waiting-1")
    expect(older.reload.driver_id).to eq(driver.id)

    expect(mock_client_for(job)).to have_received(:publish_message).with(
      "driver_available",
      correlation_key: older.id,
      vars: { driver_id: driver.id, driver_name: "Alice" },
      ttl: 30.seconds
    )
  end

  it "does not publish a message when no open requests exist" do
    driver = Delivery::Driver.create!(name: "Alice", total_mileage: 50.0, current_shipment_id: "ship-1")

    job = build_job_with_message_support(variables: delivery_vars(driver))
    described_class.perform_job(job)
    expect(job).not_to be_failed

    expect(mock_client_for(job)).not_to have_received(:publish_message)
    expect(driver.reload.current_shipment_id).to be_nil
  end

  context "when retried after partial completion" do
    it "skips mileage when driver already released, still fulfills open requests" do
      driver = Delivery::Driver.create!(name: "Alice", total_mileage: 62.5, current_shipment_id: nil)
      request = Delivery::DriverRequest.create!(shipment_id: "ship-waiting", requested_at: 1.minute.ago)

      job = build_job_with_message_support(variables: delivery_vars(driver, distance: 12.5))
      described_class.perform_job(job)
      expect(job).not_to be_failed

      expect(driver.reload.total_mileage).to eq(62.5)
      expect(driver.current_shipment_id).to eq("ship-waiting")
      expect(request.reload.driver_id).to eq(driver.id)
      expect(mock_client_for(job)).to have_received(:publish_message)
    end

    it "re-publishes message when driver already reassigned to a claimed request" do
      driver = Delivery::Driver.create!(name: "Alice", total_mileage: 62.5,
                                        current_shipment_id: "ship-waiting")
      request = Delivery::DriverRequest.create!(shipment_id: "ship-waiting", driver_id: driver.id,
                                                requested_at: 1.minute.ago)

      job = build_job_with_message_support(variables: delivery_vars(driver, distance: 12.5))
      described_class.perform_job(job)
      expect(job).not_to be_failed

      expect(driver.reload.total_mileage).to eq(62.5)
      expect(mock_client_for(job)).to have_received(:publish_message).with(
        "driver_available",
        correlation_key: request.id,
        vars: { driver_id: driver.id, driver_name: "Alice" },
        ttl: 30.seconds
      )
    end
  end
end
