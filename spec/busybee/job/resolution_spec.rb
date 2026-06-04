# frozen_string_literal: true

require "busybee/job/resolution"

RSpec.describe Busybee::Job::Resolution do
  subject(:resolution) { described_class.new }

  describe "initial state" do
    it "starts in :ready" do
      expect(resolution.status).to eq(:ready)
      expect(resolution).to be_ready
      expect(resolution).not_to be_resolved
    end

    it "has no resolution data" do
      expect(resolution.result).to be_nil
      expect(resolution.error).to be_nil
      expect(resolution.error_message).to be_nil
      expect(resolution.error_code).to be_nil
    end
  end

  describe "#resolve_to" do
    it "advances status to a terminal value" do
      resolution.resolve_to(:complete)
      expect(resolution.status).to eq(:complete)
      expect(resolution).to be_complete
      expect(resolution).to be_resolved
    end

    it "raises if called a second time (safety net; Job filters callers first)" do
      resolution.resolve_to(:complete)

      expect { resolution.resolve_to(:failed) }.
        to raise_error(RuntimeError, /already set/)
    end
  end

  describe "#set_result" do
    it "stores the Hash as a frozen HashWithIndifferentAccess" do
      resolution.set_result(processed: true)

      expect(resolution.result).to eq("processed" => true)
      expect(resolution.result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(resolution.result).to be_frozen
    end

    it "is a no-op on a second call (set-once)" do
      resolution.set_result(first: 1)
      resolution.set_result(second: 2)

      expect(resolution.result).to eq("first" => 1)
    end

    it "is a no-op when given a non-Hash value" do
      resolution.set_result("a string")

      expect(resolution.result).to be_nil
    end

    it "is a no-op when given nil" do
      resolution.set_result(nil)

      expect(resolution.result).to be_nil
    end
  end

  describe "#result_set?" do
    it "returns false before set_result is called" do
      expect(resolution.result_set?).to be(false)
    end

    it "returns true after a successful set_result" do
      resolution.set_result(processed: true)
      expect(resolution.result_set?).to be(true)
    end

    it "stays false after a rejected set_result (non-Hash)" do
      resolution.set_result("a string")
      expect(resolution.result_set?).to be(false)
    end

    it "stays false after a rejected set_result (nil)" do
      resolution.set_result(nil)
      expect(resolution.result_set?).to be(false)
    end
  end

  describe "#harvest!" do
    it "no longer extracts :result (use set_result instead)" do
      kwargs = { result: { processed: true } }
      resolution.harvest!(kwargs)

      expect(resolution.result).to be_nil
      expect(kwargs).to eq(result: { processed: true })
    end

    it "extracts and applies :error" do
      err = RuntimeError.new("boom")
      resolution.harvest!(error: err)

      expect(resolution.error).to be(err)
    end

    it "extracts and applies :error_message" do
      resolution.harvest!(error_message: "boom")

      expect(resolution.error_message).to eq("boom")
    end

    it "extracts and applies :error_code along with message and exception" do
      err = StandardError.new("not found")
      resolution.harvest!(error_code: "NOT_FOUND", error_message: "not found", error: err)

      expect(resolution.error_code).to eq("NOT_FOUND")
      expect(resolution.error_message).to eq("not found")
      expect(resolution.error).to be(err)
    end

    it "leaves non-Resolution keys in kwargs (for downstream harvesters)" do
      kwargs = { error_message: "boom", my_scratch: 1 }
      resolution.harvest!(kwargs)

      expect(kwargs).to eq(my_scratch: 1)
    end

    it "is a no-op when no Resolution data keys are present" do
      kwargs = { my_scratch: 1 }
      resolution.harvest!(kwargs)

      expect(resolution.error).to be_nil
      expect(kwargs).to eq(my_scratch: 1)
    end

    it "ignores :status and :result (both have dedicated setters)" do
      kwargs = { status: :complete, result: { x: 1 } }
      resolution.harvest!(kwargs)

      expect(resolution.status).to eq(:ready)
      expect(resolution.result).to be_nil
      expect(kwargs).to eq(status: :complete, result: { x: 1 })
    end
  end

  describe "predicate aliases" do
    it "exposes completed? as an alias for complete?" do
      resolution.resolve_to(:complete)
      expect(resolution).to be_completed
    end

    it "exposes errored? as an alias for error?" do
      resolution.resolve_to(:error)
      expect(resolution).to be_errored
    end
  end

  describe "#error_message" do
    it "returns the explicit error_message when set" do
      resolution.resolve_to(:failed)
      resolution.harvest!(error_message: "explicit")
      expect(resolution.error_message).to eq("explicit")
    end

    it "falls back to error.message when error_message is unset" do
      resolution.resolve_to(:failed)
      resolution.harvest!(error: RuntimeError.new("from-error"))
      expect(resolution.error_message).to eq("from-error")
    end

    it "is nil when both are unset" do
      expect(resolution.error_message).to be_nil
    end
  end
end
