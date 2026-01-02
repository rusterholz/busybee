# frozen_string_literal: true

require "busybee/error"

RSpec.describe Busybee::Error do
  it "is a subclass of StandardError" do
    expect(described_class.superclass).to eq(StandardError)
  end

  it "can be rescued with Busybee::Error" do
    expect { raise described_class, "test" }.to raise_error(described_class)
  end
end
