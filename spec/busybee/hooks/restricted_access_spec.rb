# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "busybee/hooks/restricted_access"

RSpec.describe Busybee::Hooks::RestrictedAccess do
  def build_event(data = {})
    ActiveSupport::HashWithIndifferentAccess.new(data).extend(described_class)
  end

  describe "restriction on extend" do
    it "prevents overwriting keys that existed at extend-time" do
      event = build_event(status: :ready, job_type: "process_order")

      expect { event[:status] = :complete }.to raise_error(FrozenError, /status/)
      expect { event[:job_type] = "other" }.to raise_error(FrozenError, /job_type/)
    end

    it "locks all keys present at extend-time" do
      event = build_event(status: :ready, job_type: "process_order", job_key: 123)

      %i[status job_type job_key].each do |key|
        expect { event[key] = "x" }.to raise_error(FrozenError), "expected #{key} to be restricted"
      end
    end
  end

  describe "annotations" do
    it "allows writing new keys not present at extend-time" do
      event = build_event(status: :ready)

      event[:my_annotation] = "hello"
      expect(event[:my_annotation]).to eq("hello")
    end

    it "allows multiple annotations" do
      event = build_event(status: :ready)

      event[:trace_id] = "abc-123"
      event[:span_id] = "def-456"
      expect(event[:trace_id]).to eq("abc-123")
      expect(event[:span_id]).to eq("def-456")
    end

    it "does not restrict annotation keys after they are written" do
      event = build_event(status: :ready)

      event[:my_annotation] = "first"
      event[:my_annotation] = "second"
      expect(event[:my_annotation]).to eq("second")
    end
  end

  describe "indifferent access interop" do
    it "blocks symbol access to a string-keyed restricted key" do
      event = build_event("status" => :ready)
      expect { event[:status] = :x }.to raise_error(FrozenError)
    end

    it "blocks string access to a symbol-keyed restricted key" do
      event = build_event(status: :ready)
      expect { event["status"] = :x }.to raise_error(FrozenError)
    end

    it "blocks store method" do
      event = build_event(status: :ready)
      expect { event.store(:status, :x) }.to raise_error(FrozenError)
    end

    it "blocks merge! on restricted keys" do
      event = build_event(status: :ready, job_type: "test")
      expect { event.merge!(status: :complete) }.to raise_error(FrozenError)
    end

    it "blocks update on restricted keys" do
      event = build_event(status: :ready)
      expect { event.update(status: :complete) }.to raise_error(FrozenError)
    end

    it "allows merge! with only annotation keys" do
      event = build_event(status: :ready)
      event.merge!(trace_id: "abc")
      expect(event[:trace_id]).to eq("abc")
    end
  end
end
