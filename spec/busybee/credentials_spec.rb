# frozen_string_literal: true

require "spec_helper"
require "busybee/credentials"

RSpec.describe Busybee::Credentials do
  describe "#channel_credentials" do
    it "raises NotImplementedError" do
      expect { described_class.new.channel_credentials }
        .to raise_error(NotImplementedError, /must implement/)
    end
  end
end
