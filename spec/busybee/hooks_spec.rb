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
      # Two distinct anonymous classes; DuplicateMethods misreads both as ::Object.name.
      # rubocop:disable Lint/DuplicateMethods
      expect(described_class.match?(/Order/, Class.new { def self.name = "OrderWorker" })).to be true
      expect(described_class.match?(/Order/, Class.new { def self.name = "ShipmentWorker" })).to be false
      # rubocop:enable Lint/DuplicateMethods
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

  describe "hook context" do
    describe ".context" do
      it "returns an empty hash by default" do
        expect(described_class.context).to eq({})
      end
    end

    describe ".with_context" do
      it "makes context available inside the block" do
        described_class.with_context(worker_class: String, job_key: 123) do
          expect(described_class.context).to eq(worker_class: String, job_key: 123)
        end
      end

      it "restores previous context after the block" do
        described_class.with_context(worker_class: String) do
          # inside
        end
        expect(described_class.context).to eq({})
      end

      it "restores context even if block raises" do
        described_class.with_context(worker_class: String) { raise "boom" } rescue nil # rubocop:disable Style/RescueModifier
        expect(described_class.context).to eq({})
      end

      it "nests — inner context merges with outer" do
        described_class.with_context(worker_class: String) do
          described_class.with_context(job_key: 456) do
            expect(described_class.context).to eq(worker_class: String, job_key: 456)
          end
          # outer still intact
          expect(described_class.context).to eq(worker_class: String)
        end
      end

      it "inner context can override outer keys" do
        described_class.with_context(worker_class: String) do
          described_class.with_context(worker_class: Integer) do
            expect(described_class.context[:worker_class]).to eq(Integer)
          end
          expect(described_class.context[:worker_class]).to eq(String)
        end
      end

      it "is thread-isolated" do
        described_class.with_context(worker_class: String) do
          result = Thread.new { described_class.context }.value
          expect(result).to eq({})
        end
      end
    end

    describe "context integration with build_event" do
      it "promotes allowed context keys to event top level" do
        described_class.with_context(worker_class: String, job_key: 789) do
          event = described_class.build_event(:job, status: :ready)
          expect(event[:worker_class]).to eq(String)
          expect(event[:job_key]).to eq(789)
        end
      end

      it "explicit data wins over context" do
        described_class.with_context(worker_class: String) do
          event = described_class.build_event(:job, worker_class: Integer, status: :ready)
          expect(event[:worker_class]).to eq(Integer)
        end
      end

      it "does not promote context keys outside the noun's allowlist" do
        described_class.with_context(worker_class: String, custom_thing: "hello") do
          event = described_class.build_event(:job, status: :ready)
          expect(event[:worker_class]).to eq(String)
          expect(event).not_to have_key("custom_thing")
        end
      end

      it "stashes full context (including non-promoted keys) in event[:context]" do
        described_class.with_context(worker_class: String, trace_id: "abc") do
          event = described_class.build_event(:job, status: :ready)
          expect(event[:context]).to eq("worker_class" => String, "trace_id" => "abc")
        end
      end

      it "freezes the context snapshot on the event" do
        described_class.with_context(worker_class: String) do
          event = described_class.build_event(:job, status: :ready)
          expect(event[:context]).to be_frozen
        end
      end

      it "event[:context] is restricted (cannot be replaced)" do
        described_class.with_context(worker_class: String) do
          event = described_class.build_event(:job, status: :ready)
          expect { event[:context] = {} }.to raise_error(FrozenError)
        end
      end

      it "provides empty frozen context when none is pushed" do
        event = described_class.build_event(:job, status: :ready)
        expect(event[:context]).to eq({})
        expect(event[:context]).to be_frozen
      end

      it "does not promote call-disallowed keys even when in context" do
        described_class.with_context(worker_class: String, job_key: 789) do
          event = described_class.build_event(:call, method: :complete_job)
          expect(event).not_to have_key("worker_class")
          expect(event).not_to have_key("job_key")
          expect(event[:context][:worker_class]).to eq(String)
        end
      end
    end
  end

  describe ".run_hooks" do
    after { described_class.reset! }

    let(:event) { described_class.build_event(:job, status: :ready, job_type: "test") }

    it "calls matching hooks in FIFO order" do
      results = []
      Busybee.before_job { results << :first }
      Busybee.before_job { results << :second }

      described_class.run_hooks(:before_job, event)
      expect(results).to eq(%i[first second])
    end

    it "passes the event to each hook" do
      received = nil
      Busybee.before_job { |e| received = e }

      described_class.run_hooks(:before_job, event)
      expect(received).to be(event)
    end

    it "does nothing when no hooks are registered" do
      expect { described_class.run_hooks(:before_job, event) }.not_to raise_error
    end

    context "with swallow_errors: false (default, propagating)" do
      it "lets errors propagate" do
        Busybee.before_job { raise "boom" }

        expect { described_class.run_hooks(:before_job, event) }.to raise_error(RuntimeError, "boom")
      end

      it "stops at the first error" do
        results = []
        Busybee.before_job { raise "boom" }
        Busybee.before_job { results << :second }

        described_class.run_hooks(:before_job, event) rescue nil # rubocop:disable Style/RescueModifier
        expect(results).to eq([])
      end
    end

    context "with swallow_errors: true (swallowing)" do
      it "swallows errors and continues to the next hook" do
        results = []
        Busybee.after_job { raise "boom" }
        Busybee.after_job { results << :second }

        described_class.run_hooks(:after_job, event, swallow_errors: true)
        expect(results).to eq([:second])
      end

      it "logs swallowed errors" do
        logger = instance_double(Logger, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.after_job { raise "boom" }

        described_class.run_hooks(:after_job, event, swallow_errors: true)
        expect(logger).to have_received(:error).with(/Hook error.*swallowed.*RuntimeError.*boom/)
      end

      it "always propagates Busybee::Worker::Shutdown" do
        Busybee.after_job { raise Busybee::Worker::Shutdown.new(worker: nil) }

        expect do
          described_class.run_hooks(:after_job, event, swallow_errors: true)
        end.to raise_error(Busybee::Worker::Shutdown)
      end

      it "propagates shutdown_on errors from worker class config" do
        worker_class = Class.new(Busybee::Worker) do
          shutdown_on RuntimeError
        end
        event = described_class.build_event(:job, status: :ready, worker_class: worker_class)
        Busybee.after_job { raise "db gone" }

        expect do
          described_class.run_hooks(:after_job, event, swallow_errors: true)
        end.to raise_error(Busybee::Worker::Shutdown)
      end

      it "propagates shutdown_on errors from gem-level config" do
        original = Busybee.shutdown_on_errors
        begin
          Busybee.shutdown_on_errors = [RuntimeError]
          Busybee.after_job { raise "db gone" }

          expect do
            described_class.run_hooks(:after_job, event, swallow_errors: true)
          end.to raise_error(Busybee::Worker::Shutdown)
        ensure
          Busybee.shutdown_on_errors = original
        end
      end
    end

    context "with prefiltering" do
      it "skips hooks whose filters do not match" do
        results = []
        Busybee.before_job(status: :failed) { results << :filtered }
        Busybee.before_job { results << :unfiltered }

        described_class.run_hooks(:before_job, event) # event has status: :ready
        expect(results).to eq([:unfiltered])
      end
    end
  end

  describe ".run_around_chain" do
    after { described_class.reset! }

    let(:event) { described_class.build_event(:job, status: :ready, job_type: "test", result: {}) }

    it "calls the core block when no around hooks are registered" do
      called = false
      described_class.run_around_chain(:around_job, event) { called = true }
      expect(called).to be true
    end

    it "wraps the core block with a single around hook" do
      results = []
      Busybee.around_job do |_event, perform|
        results << :before
        perform.call
        results << :after
      end

      described_class.run_around_chain(:around_job, event) { results << :core }
      expect(results).to eq(%i[before core after])
    end

    it "nests 3 hooks in FIFO order (outermost registered first)" do
      results = []
      %i[outer middle inner].each do |label|
        Busybee.around_job do |_event, perform|
          results << :"#{label}_before"
          perform.call
          results << :"#{label}_after"
        end
      end

      described_class.run_around_chain(:around_job, event) { results << :core }
      expect(results).to eq(%i[
                              outer_before middle_before inner_before
                              core
                              inner_after middle_after outer_after
                            ])
    end

    it "passes the event to each hook" do
      received = []
      Busybee.around_job do |e, perform|
        received << e
        perform.call
      end

      described_class.run_around_chain(:around_job, event) {} # rubocop:disable Lint/EmptyBlock
      expect(received).to eq([event])
    end

    it "stores the core block return value in event[:result] (Option B2)" do
      described_class.run_around_chain(:around_job, event) { { order_id: 123 } }
      expect(event[:result]).to eq("order_id" => 123)
    end

    it "extracts result from event even when middleware forgets to return it" do
      Busybee.around_job do |_event, perform|
        perform.call
        "middleware forgot to return result"
      end

      described_class.run_around_chain(:around_job, event) { { order_id: 123 } }
      expect(event[:result]).to eq("order_id" => 123)
    end

    it "lets errors from around hooks propagate" do
      Busybee.around_job { |_event, _perform| raise "middleware boom" }

      expect do
        described_class.run_around_chain(:around_job, event) { "core" }
      end.to raise_error(RuntimeError, "middleware boom")
    end

    it "lets errors from the core block propagate through middleware" do
      results = []
      Busybee.around_job do |_event, perform|
        results << :before
        perform.call
      rescue RuntimeError
        results << :rescued
        raise
      end

      expect do
        described_class.run_around_chain(:around_job, event) { raise "core boom" }
      end.to raise_error(RuntimeError, "core boom")
      expect(results).to eq(%i[before rescued])
    end

    context "with prefiltering" do
      it "excludes non-matching hooks from the chain" do
        results = []
        Busybee.around_job(status: :failed) do |_event, perform|
          results << :filtered
          perform.call
        end
        Busybee.around_job do |_event, perform|
          results << :unfiltered
          perform.call
        end

        described_class.run_around_chain(:around_job, event) { results << :core }
        expect(results).to eq(%i[unfiltered core])
      end
    end
  end
end
