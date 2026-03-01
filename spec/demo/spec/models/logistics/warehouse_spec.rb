# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Logistics::Warehouse do
  let(:warehouse) do
    described_class.create!(id: SecureRandom.uuid, name: "East Coast Hub", lat: 40.7, lon: -74.0)
  end

  describe "#as_json" do
    it "returns id, name, and address coordinates" do
      expect(warehouse.as_json).to eq({
                                        id: warehouse.id,
                                        name: "East Coast Hub",
                                        address: { lat: 40.7, lon: -74.0 }
                                      })
    end
  end
end
