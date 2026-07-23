# frozen_string_literal: true

require_relative "../rails_helper"

RSpec.describe "Demo.worker_name" do # rubocop:disable RSpec/DescribeClass
  it "adds a random per-boot suffix so each container boot is a distinct incarnation" do
    expect(Demo.worker_name(domain: nil, random: "ab12c")).to eq("worker-ab12c")
  end

  it "prefixes the domain for legibility when DEMO_DOMAIN is set" do
    expect(Demo.worker_name(domain: "logistics", random: "ab12c")).to eq("logistics-worker-ab12c")
  end

  it "treats a blank domain as absent" do
    expect(Demo.worker_name(domain: "", random: "ab12c")).to eq("worker-ab12c")
  end
end
