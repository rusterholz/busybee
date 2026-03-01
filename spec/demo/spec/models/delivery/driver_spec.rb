# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Delivery::Driver do
  let!(:busy_driver) do
    described_class.create!(id: SecureRandom.uuid, name: "Bob", total_mileage: 100.0,
                            current_shipment_id: SecureRandom.uuid)
  end

  let!(:available_low) do
    described_class.create!(id: SecureRandom.uuid, name: "Alice", total_mileage: 50.0)
  end

  let!(:available_high) do
    described_class.create!(id: SecureRandom.uuid, name: "Carol", total_mileage: 200.0)
  end

  describe ".available" do
    it "returns only drivers with no current shipment" do
      result = described_class.available
      expect(result).to include(available_low, available_high)
      expect(result).not_to include(busy_driver)
    end
  end

  describe ".by_mileage" do
    it "orders drivers by total mileage ascending" do
      result = described_class.by_mileage.to_a
      mileages = result.map(&:total_mileage)
      expect(mileages).to eq(mileages.sort)
    end
  end

  describe ".available.by_mileage" do
    it "returns the lowest-mileage available driver first" do
      expect(described_class.available.by_mileage.first).to eq(available_low)
    end
  end
end
