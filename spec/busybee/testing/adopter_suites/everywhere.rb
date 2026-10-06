# frozen_string_literal: true

# An adopter's suite that includes busybee's helpers everywhere, in one line.
# Run in its own process by testing_spec.rb.
require "busybee/testing"

RSpec.configure { |config| config.include Busybee::Testing::Helpers }

RSpec.describe "a group that hasn't opted in" do
  it "has every busybee helper and matcher" do
    expect(methods).to include(*Busybee::Testing::Helpers.public_instance_methods, :complete_job)
  end
end
