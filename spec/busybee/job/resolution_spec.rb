# frozen_string_literal: true

require "busybee/job/resolution"

RSpec.describe Busybee::Job::Resolution do
  subject(:resolution) { described_class.new }

  describe "OWNED_KEYS" do
    it "lists the status + outcome-data keys reserved at the set_context boundary" do
      expect(described_class::OWNED_KEYS).to eq(%i[status result error error_message error_code])
    end
  end

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

    it "is a no-op on a second call (set-once on the result axis)" do
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

    it "is independent of a prior set_error (orthogonal axes)" do
      err = RuntimeError.new("boom")
      resolution.set_error(err)
      resolution.set_result(processed: true)

      expect(resolution.result).to eq("processed" => true)
      expect(resolution.error).to be(err)
    end
  end

  describe "#set_error" do
    it "stores the Exception as @error" do
      err = RuntimeError.new("boom")
      resolution.set_error(err)

      expect(resolution.error).to be(err)
    end

    it "accepts a Hash with :error_message" do
      resolution.set_error(error_message: "boom")
      expect(resolution.error_message).to eq("boom")
    end

    it "accepts a Hash with :error_code, :error_message, :error together" do
      err = StandardError.new("missing")
      resolution.set_error(error_code: "NOT_FOUND", error_message: "missing", error: err)

      expect(resolution.error_code).to eq("NOT_FOUND")
      expect(resolution.error_message).to eq("missing")
      expect(resolution.error).to be(err)
    end

    it "is a no-op on a second call (set-once on the error axis)" do
      first = RuntimeError.new("first")
      second = RuntimeError.new("second")
      resolution.set_error(first)
      resolution.set_error(second)

      expect(resolution.error).to be(first)
    end

    it "is independent of a prior set_result (orthogonal axes)" do
      resolution.set_result(processed: true)
      err = RuntimeError.new("boom")
      resolution.set_error(err)

      expect(resolution.error).to be(err)
      expect(resolution.result).to eq("processed" => true)
    end

    it "drops explicit nils within a recognized bundle, sets the rest" do
      resolution.set_error(error: nil, error_code: "X")

      expect(resolution.error).to be_nil
      expect(resolution.error_code).to eq("X")
      expect(resolution.error_set?).to be(true)
    end

    it "is a no-op when given a non-Exception, non-Hash value" do
      resolution.set_error("a bare string")

      expect(resolution.error).to be_nil
      expect(resolution.error_set?).to be(false)
    end

    it "is a no-op when given a Hash with no recognized non-nil keys" do
      resolution.set_error(my_scratch: 1)

      expect(resolution.error).to be_nil
      expect(resolution.error_set?).to be(false)
    end

    it "is a no-op when given a Hash whose recognized keys are all nil" do
      resolution.set_error(error: nil, error_message: nil)

      expect(resolution.error_set?).to be(false)
    end
  end

  describe "#result_set?" do
    it "returns false before any outcome is set" do
      expect(resolution.result_set?).to be(false)
    end

    it "returns true after a successful set_result" do
      resolution.set_result(processed: true)
      expect(resolution.result_set?).to be(true)
    end

    it "is unaffected by set_error (orthogonal to the error axis)" do
      resolution.set_error(RuntimeError.new("boom"))
      expect(resolution.result_set?).to be(false)
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

  describe "#error_set?" do
    it "returns false before any outcome is set" do
      expect(resolution.error_set?).to be(false)
    end

    it "returns true after set_error with an Exception" do
      resolution.set_error(RuntimeError.new("boom"))
      expect(resolution.error_set?).to be(true)
    end

    it "returns true after set_error with any error-shaped key" do
      resolution.set_error(error_code: "NOT_FOUND")
      expect(resolution.error_set?).to be(true)
    end

    it "is unaffected by set_result (orthogonal to the result axis)" do
      resolution.set_result(processed: true)
      expect(resolution.error_set?).to be(false)
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
      resolution.set_error(error_message: "explicit")
      expect(resolution.error_message).to eq("explicit")
    end

    it "falls back to error.message when error_message is unset" do
      resolution.resolve_to(:failed)
      resolution.set_error(RuntimeError.new("from-error"))
      expect(resolution.error_message).to eq("from-error")
    end

    it "is nil when both are unset" do
      expect(resolution.error_message).to be_nil
    end
  end
end
