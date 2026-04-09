# frozen_string_literal: true

require "busybee/hooks"

RSpec.describe Busybee::Hooks do
  describe ".build_event" do
    subject(:event) { described_class.build_event(:job, data) }

    let(:data) do
      {
        job_type: "process_order",
        worker_class: String,
        status: :complete,
        bpmn_process_id: "order-flow",
        job_key: 12_345,
        activated_at: 1000.0,
        execution_started_at: 1000.5,
        perform_started_at: 1000.8,
        perform_finished_at: 1001.3,
        resolved_at: 1001.4,
        executed_at: 1001.6
      }
    end

    it "returns a HashWithIndifferentAccess" do
      expect(event).to be_a(ActiveSupport::HashWithIndifferentAccess)
    end

    it "supports method-style access via HashAccess" do
      expect(event.job_type).to eq("process_order")
      expect(event.job_key).to eq(12_345)
    end

    it "restricts framework keys from modification" do
      expect { event[:status] = :failed }.to raise_error(FrozenError)
    end

    it "allows annotations on new keys" do
      event[:trace_id] = "abc-123"
      expect(event[:trace_id]).to eq("abc-123")
    end

    it "provides noun-specific predicates" do
      expect(event).to be_completed
      expect(event).not_to be_failed
    end

    it "provides computed durations" do
      expect(event.perform_duration_ms).to eq(500.0)
      expect(event.buffer_latency_ms).to eq(500.0)
    end

    it "provides tags" do
      expect(event.tags).to include("job_type" => "process_order", "status" => :complete)
    end

    it "provides error_message" do
      err_event = described_class.build_event(:job, status: :failed, error: RuntimeError.new("boom"))
      expect(err_event.error_message).to eq("boom")
    end

    it "raises for unknown noun" do
      expect { described_class.build_event(:unknown, {}) }.to raise_error(ArgumentError, /unknown/)
    end

    it "accepts :worker noun" do
      event = described_class.build_event(:worker, worker_class: String, job_type: "test")
      expect(event.error_message).to be_nil
    end

    it "accepts :call noun" do
      event = described_class.build_event(:call, method: :complete_job)
      expect(event.error_message).to be_nil
    end
  end

  describe "hook storage" do
    after { described_class.reset! }

    described_class::HOOK_TYPES.each do |hook_type|
      it "stores #{hook_type} hooks in an array" do
        expect(described_class.hooks_for(hook_type)).to eq([])
      end
    end

    it "raises for unknown hook type" do
      expect { described_class.hooks_for(:bogus) }.to raise_error(ArgumentError, /bogus/)
    end

    describe ".reset!" do
      it "clears all hook arrays" do
        described_class.hooks_for(:before_job) << { callback: -> {}, filters: {} }
        described_class.reset!
        expect(described_class.hooks_for(:before_job)).to eq([])
      end
    end
  end

  describe "registration" do
    after { described_class.reset! }

    it "registers a before_job hook via Busybee.configure" do
      callback = proc { |_event| }
      Busybee.configure { |c| c.before_job(&callback) }

      hooks = described_class.hooks_for(:before_job)
      expect(hooks.length).to eq(1)
      expect(hooks.first[:callback]).to be(callback)
      expect(hooks.first[:filters]).to eq({})
    end

    it "registers with filter kwargs" do
      Busybee.configure { |c| c.after_job(status: :failed) { |_| } } # rubocop:disable Lint/EmptyBlock

      hook = described_class.hooks_for(:after_job).first
      expect(hook[:filters]).to eq(status: :failed)
    end

    it "preserves FIFO ordering" do
      results = []
      Busybee.configure do |c|
        c.before_job { results << :first }
        c.before_job { results << :second }
        c.before_job { results << :third }
      end

      hooks = described_class.hooks_for(:before_job)
      expect(hooks.length).to eq(3)
      hooks.each { |h| h[:callback].call(nil) }
      expect(results).to eq(%i[first second third])
    end

    it "supports all 12 hook types" do
      described_class::HOOK_TYPES.each do |type|
        Busybee.configure { |c| c.public_send(type) { |_| } } # rubocop:disable Lint/EmptyBlock
        expect(described_class.hooks_for(type).length).to eq(1), "expected #{type} to have 1 hook"
      end
    end

    it "requires a block" do
      expect { Busybee.before_job }.to raise_error(ArgumentError, /block/)
    end
  end

  describe ".match?" do
    it "matches exact symbol" do
      expect(described_class.match?(:failed, :failed)).to be true
      expect(described_class.match?(:failed, :complete)).to be false
    end

    it "matches exact string" do
      expect(described_class.match?("process_order", "process_order")).to be true
      expect(described_class.match?("process_order", "other")).to be false
    end

    it "matches regex" do
      expect(described_class.match?(/order/, "process_order")).to be true
      expect(described_class.match?(/order/, "send_email")).to be false
    end

    it "matches Class via is_a? (case equality)" do
      expect(described_class.match?(RuntimeError, RuntimeError.new("boom"))).to be true
      expect(described_class.match?(RuntimeError, StandardError.new("boom"))).to be false
    end

    it "matches Proc/Lambda" do
      filter = ->(v) { v.start_with?("order") }
      expect(described_class.match?(filter, "order_123")).to be true
      expect(described_class.match?(filter, "shipment_456")).to be false
    end

    it "falls back to Class name when value is a Class" do
      expect(described_class.match?(/Order/, Class.new { def self.name = "OrderWorker" })).to be true
      expect(described_class.match?(/Order/, Class.new { def self.name = "ShipmentWorker" })).to be false
    end

    it "matches Class by exact name string (useful for load-order issues)" do
      klass = Class.new { def self.name = "OrderWorker" }
      expect(described_class.match?("OrderWorker", klass)).to be true
      expect(described_class.match?("ShipmentWorker", klass)).to be false
    end

    it "does not use name fallback for non-Class values" do
      expect(described_class.match?(/boom/, RuntimeError.new("boom"))).to be false
    end
  end

  describe ".matches?" do
    it "returns true when all filters match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      event = { "status" => :failed, "job_type" => "process_order" }
      expect(described_class.matches?(hook, event)).to be true
    end

    it "returns false when any filter does not match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      event = { "status" => :complete, "job_type" => "process_order" }
      expect(described_class.matches?(hook, event)).to be false
    end

    it "returns true (vacuous truth) when filters are empty" do
      hook = { filters: {} }
      event = { "status" => :ready }
      expect(described_class.matches?(hook, event)).to be true
    end
  end

  describe "filter kwargs validation" do
    after { described_class.reset! }

    let(:noop) { proc { |_| "registered" } }

    it "accepts valid job filter kwargs" do
      expect do
        Busybee.before_job(job_type: "test", worker_class: /Order/, status: :failed,
                           bpmn_process_id: "flow", error: RuntimeError, &noop)
      end.not_to raise_error
    end

    it "rejects unknown job filter kwargs" do
      expect do
        Busybee.before_job(method: :complete_job, &noop)
      end.to raise_error(ArgumentError, /method/)
    end

    it "accepts valid worker filter kwargs" do
      expect do
        Busybee.on_worker_started(worker_class: /Order/, job_type: "test",
                                  worker_mode: :polling, error: RuntimeError, &noop)
      end.not_to raise_error
    end

    it "rejects unknown worker filter kwargs" do
      expect do
        Busybee.on_worker_started(status: :failed, &noop)
      end.to raise_error(ArgumentError, /status/)
    end

    it "accepts valid call filter kwargs" do
      expect do
        Busybee.before_call(method: :complete_job, result: :completed, error: RuntimeError, &noop)
      end.not_to raise_error
    end

    it "rejects unknown call filter kwargs" do
      expect do
        Busybee.before_call(job_type: "test", &noop)
      end.to raise_error(ArgumentError, /job_type/)
    end
  end
end
