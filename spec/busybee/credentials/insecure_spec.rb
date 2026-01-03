# frozen_string_literal: true

require "spec_helper"
require "busybee/credentials/insecure"

RSpec.describe Busybee::Credentials::Insecure do
  describe "#channel_credentials" do
    it "returns :this_channel_is_insecure" do
      expect(described_class.new.channel_credentials).to eq(:this_channel_is_insecure)
    end
  end

  it "is a subclass of Credentials" do
    expect(described_class.superclass).to eq(Busybee::Credentials)
  end
end
