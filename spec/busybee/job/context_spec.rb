# frozen_string_literal: true

require "busybee/job/context"

RSpec.describe Busybee::Job::Context do
  subject(:context) { described_class.new }

  describe "initial state" do
    it "is empty" do
      expect(context.to_h).to eq({})
    end

    it "returns nil for any key" do
      expect(context[:anything]).to be_nil
    end
  end

  describe "scratch storage" do
    it "stores and retrieves values by key" do
      context[:span] = "trace-span"
      expect(context[:span]).to eq("trace-span")
    end

    it "overwrites on repeat assignment" do
      context[:span] = "first"
      context[:span] = "second"
      expect(context[:span]).to eq("second")
    end
  end

  describe "#absorb" do
    it "merges kwargs into the bag without mutating them" do
      kwargs = { span: "trace", foo: 1, bar: 2 }
      context.absorb(kwargs)

      expect(context[:span]).to eq("trace")
      expect(context[:foo]).to eq(1)
      expect(context[:bar]).to eq(2)
      expect(kwargs).to eq(span: "trace", foo: 1, bar: 2)
    end

    it "merges into existing data (later absorbs overwrite earlier)" do
      context[:span] = "first"
      context.absorb(span: "second", foo: 1)

      expect(context[:span]).to eq("second")
      expect(context[:foo]).to eq(1)
    end
  end

  describe "#context_tags" do
    it "is always empty (hook authors don't mark scratch keys tag-worthy)" do
      context[:user_tier] = "premium"
      context[:request_id] = "abc-123"

      expect(context.context_tags).to eq({})
    end
  end

  describe "#logging_context" do
    it "returns primitive-valued scratch entries" do
      context[:str] = "hello"
      context[:sym] = :foo
      context[:int] = 42
      context[:float] = 1.5
      context[:bool_t] = true
      context[:bool_f] = false
      context[:nil_value] = nil

      expect(context.logging_context).to eq(
        str: "hello", sym: :foo, int: 42, float: 1.5,
        bool_t: true, bool_f: false, nil_value: nil
      )
    end

    it "includes Time, Date, and DateTime values" do
      now = Time.now
      today = Date.today
      noon = DateTime.new(2026, 5, 31, 12)

      context[:now] = now
      context[:today] = today
      context[:noon] = noon

      expect(context.logging_context).to eq(now: now, today: today, noon: noon)
    end

    it "includes ActiveSupport::TimeWithZone values (covered transitively via is_a?(Time))" do
      require "active_support/all"
      Time.zone = "UTC"
      tz = Time.now.in_time_zone

      context[:tz] = tz

      expect(tz.is_a?(Time)).to be(true), "AS::TimeWithZone#is_a?(Time) is the basis for this case"
      expect(context.logging_context[:tz]).to be(tz)
    end

    it "drops non-primitive values (Hash, Array, custom objects)" do
      context[:span] = Object.new
      context[:hash] = { nested: 1 }
      context[:array] = [1, 2, 3]
      context[:str] = "kept"

      expect(context.logging_context).to eq(str: "kept")
    end
  end
end
