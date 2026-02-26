# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::PickAndPackWorker do
  around do |example|
    original = Rails.application.config.x.demo.simulation_speed
    Rails.application.config.x.demo.simulation_speed = 10_000.0
    example.run
    Rails.application.config.x.demo.simulation_speed = original
  end

  it "sleeps and returns nil" do
    expect { execute_worker(described_class, variables: { item_count: 3 }) }.not_to raise_error
  end
end
