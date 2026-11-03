# frozen_string_literal: true

require "busybee/testing/no_jobs_available"

RSpec.describe Busybee::Testing::NoJobsAvailable do
  it "is rescued under its former name" do
    rescued = begin
      raise described_class, "nothing waiting"
    rescue Busybee::Testing::NoJobAvailable => e
      e
    end

    expect(rescued).to be_a(described_class)
    expect(rescued.class.name).to eq("Busybee::Testing::NoJobsAvailable")
  end

  it "reaches a raise_error naming its former name" do
    expect { raise described_class }.to raise_error(Busybee::Testing::NoJobAvailable)
  end
end
