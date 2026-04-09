# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/hooks/event_access"

RSpec.describe Busybee::Hooks::EventAccess do
  # EventAccess is the base mixin. Test it directly to verify shared behavior.
  # Noun-specific behavior (predicates, durations, tags) is tested in noun specs.
  def build_event(data = {})
    ActiveSupport::HashWithIndifferentAccess.new(data).extend(described_class)
  end

  describe "#error_message" do
    it "returns error_message key when present" do
      event = build_event(error_message: "Something broke")
      expect(event.error_message).to eq("Something broke")
    end

    it "falls back to error.message" do
      event = build_event(error: RuntimeError.new("kaboom"))
      expect(event.error_message).to eq("kaboom")
    end

    it "prefers error_message over error.message" do
      event = build_event(
        error_message: "BPMN error: ORDER_NOT_FOUND",
        error: RuntimeError.new("kaboom")
      )
      expect(event.error_message).to eq("BPMN error: ORDER_NOT_FOUND")
    end

    it "returns nil when neither is present" do
      event = build_event(status: :ready)
      expect(event.error_message).to be_nil
    end
  end

  describe "#compute_ms (via submodule)" do
    # compute_ms is private, but we can test it through a module that uses it.
    # This verifies the shared helper works correctly for any noun.
    let(:test_module) do
      Module.new do
        include Busybee::Hooks::EventAccess

        def test_duration_ms
          compute_ms(:from, :to)
        end
      end
    end

    def build_test_event(data = {})
      ActiveSupport::HashWithIndifferentAccess.new(data).extend(test_module)
    end

    it "computes millisecond difference between two monotonic timestamps" do
      event = build_test_event(from: 100.0, to: 100.5)
      expect(event.test_duration_ms).to eq(500.0)
    end

    it "returns nil when from timestamp is missing" do
      expect(build_test_event(to: 100.5).test_duration_ms).to be_nil
    end

    it "returns nil when to timestamp is missing" do
      expect(build_test_event(from: 100.0).test_duration_ms).to be_nil
    end

    it "returns nil when both timestamps are missing" do
      expect(build_test_event({}).test_duration_ms).to be_nil
    end

    it "rounds to one decimal place" do
      event = build_test_event(from: 100.0, to: 100.1234)
      expect(event.test_duration_ms).to eq(123.4)
    end
  end
end
