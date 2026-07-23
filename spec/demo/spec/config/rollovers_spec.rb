# frozen_string_literal: true

require_relative "../rails_helper"

# Simulated rollovers (config/initializers/busybee.rb) raise Sim::Rollover on a
# per-job hazard. That's a running-simulation behaviour — under test, worker specs
# invoke perform directly, so an enabled hazard would randomly fail unrelated specs.
RSpec.describe "Demo rollovers" do # rubocop:disable RSpec/DescribeClass
  it "are disabled in the test environment so worker specs stay deterministic" do
    expect(Rails.application.config.x.demo.rollovers_enabled).to be(false)
  end
end
