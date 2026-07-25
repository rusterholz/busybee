# frozen_string_literal: true

require "busybee/hooks"

RSpec.describe Busybee::Hooks do
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

    it "maps every hook type to a filter noun (HOOK_NOUN is explicit, not derived)" do
      expect(described_class::HOOK_NOUN.keys).to match_array(described_class::HOOK_TYPES)
      expect(described_class::HOOK_NOUN.values.uniq).to match_array(described_class::FILTER_KEYS.keys)
    end

    describe ".reset!" do
      it "clears all hook arrays" do
        described_class.hooks_for(:before_perform) << { callback: -> {}, filters: {} }
        described_class.reset!
        expect(described_class.hooks_for(:before_perform)).to eq([])
      end
    end
  end

  describe "registration" do
    after { described_class.reset! }

    it "registers a before_perform hook via Busybee.configure" do
      callback = proc { |_event| }
      Busybee.configure { |c| c.before_perform(&callback) }

      hooks = described_class.hooks_for(:before_perform)
      expect(hooks.length).to eq(1)
      expect(hooks.first[:callback]).to be(callback)
      expect(hooks.first[:filters]).to eq({})
    end

    it "registers with filter kwargs" do
      Busybee.configure { |c| c.after_perform(status: :failed) { |_| } } # rubocop:disable Lint/EmptyBlock

      hook = described_class.hooks_for(:after_perform).first
      expect(hook[:filters]).to eq(status: :failed)
    end

    it "preserves FIFO ordering" do
      results = []
      Busybee.configure do |c|
        c.before_perform { results << :first }
        c.before_perform { results << :second }
        c.before_perform { results << :third }
      end

      hooks = described_class.hooks_for(:before_perform)
      expect(hooks.length).to eq(3)
      hooks.each { |h| h[:callback].call(nil) }
      expect(results).to eq(%i[first second third])
    end

    it "supports all 13 hook types" do
      described_class::HOOK_TYPES.each do |type|
        Busybee.configure { |c| c.public_send(type) { |_| } } # rubocop:disable Lint/EmptyBlock
        expect(described_class.hooks_for(type).length).to eq(1), "expected #{type} to have 1 hook"
      end
    end

    it "requires a block" do
      expect { Busybee.before_perform }.to raise_error(ArgumentError, /block/)
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

    it "matches Class by identity (filter and value are the same Class)" do
      klass = Class.new { def self.name = "OrderWorker" }
      other = Class.new { def self.name = "ShipmentWorker" }
      expect(described_class.match?(klass, klass)).to be true
      expect(described_class.match?(klass, other)).to be false
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

    it "matches any element when the filter is an array" do
      expect(described_class.match?(%i[failed error], :error)).to be true
      expect(described_class.match?(%i[failed error], :complete)).to be false
    end

    it "applies each element matcher (string, regex, class name) inside an array" do
      expect(described_class.match?(["create_shipment", /assign/], "assign_driver")).to be true
      expect(described_class.match?(["create_shipment", /assign/], "load_warehouses")).to be false
    end

    it "treats an empty array as matching nothing" do
      expect(described_class.match?([], :anything)).to be false
    end
  end

  describe ".matches?" do
    # Targets are Job-like objects whose attribute names are looked up via
    # public_send. Struct stand-ins keep the matching tests focused on the
    # matching logic without Job construction overhead.
    let(:target_class) { Struct.new(:status, :job_type, keyword_init: true) }

    it "returns true when all filters match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      target = target_class.new(status: :failed, job_type: "process_order")
      expect(described_class.matches?(hook, target)).to be true
    end

    it "returns false when any filter does not match" do
      hook = { filters: { status: :failed, job_type: /order/ } }
      target = target_class.new(status: :complete, job_type: "process_order")
      expect(described_class.matches?(hook, target)).to be false
    end

    it "returns true (vacuous truth) when filters are empty" do
      hook = { filters: {} }
      target = target_class.new(status: :ready, job_type: nil)
      expect(described_class.matches?(hook, target)).to be true
    end
  end

  describe "filter kwargs validation" do
    after { described_class.reset! }

    let(:noop) { proc { |_| "registered" } }

    it "accepts valid job filter kwargs" do
      expect do
        Busybee.before_perform(job_type: "test", worker_class: /Order/, status: :failed,
                               bpmn_process_id: "flow", buffered: true, error: RuntimeError, &noop)
      end.not_to raise_error
    end

    it "rejects unknown job filter kwargs" do
      expect do
        Busybee.before_perform(method: :complete_job, &noop)
      end.to raise_error(ArgumentError, /method/)
    end

    it "accepts valid worker filter kwargs" do
      expect do
        Busybee.on_worker_started(worker_class: /Order/, job_type: "test",
                                  worker_mode: :polling, reason: :error,
                                  error: RuntimeError, &noop)
      end.not_to raise_error
    end

    it "rejects unknown worker filter kwargs" do
      expect do
        Busybee.on_worker_started(status: :failed, &noop)
      end.to raise_error(ArgumentError, /status/)
    end

    it "registers the on_worker_stop_requested hook type" do
      expect { Busybee.on_worker_stop_requested(&noop) }.not_to raise_error
    end

    it "accepts valid call filter kwargs" do
      expect do
        Busybee.before_call(rpc: :complete_job, status: :errored, grpc_status: :ok,
                            error: "Busybee::GRPC::Error", &noop)
      end.not_to raise_error
    end

    it "rejects unknown call filter kwargs (including the retired method/result keys)" do
      expect do
        Busybee.before_call(method: :complete_job, &noop)
      end.to raise_error(ArgumentError, /method/)
    end

    it "rejects the retired error_class: key on every noun (error: is the one error filter)" do
      expect { Busybee.on_worker_started(error_class: "RuntimeError", &noop) }.
        to raise_error(ArgumentError, /error_class/)
      expect { Busybee.before_call(error_class: "RuntimeError", &noop) }.
        to raise_error(ArgumentError, /error_class/)
      expect { Busybee.before_perform(error_class: "RuntimeError", &noop) }.
        to raise_error(ArgumentError, /error_class/)
    end

    it "drops a top-level nil filter value at registration (nil = do not filter on this key)" do
      Busybee.before_perform(error: nil, job_type: nil, &noop)
      expect(described_class.hooks_for(:before_perform).first[:filters]).to eq({})
    end

    it "rejects nil inside an error: array, pointing at error: false" do
      expect { Busybee.before_perform(error: [nil, RuntimeError], &noop) }.
        to raise_error(ArgumentError, /error: false/)
    end

    it "rejects matcher types the error: table does not name" do
      expect { Busybee.before_perform(error: :not_a_matcher, &noop) }.
        to raise_error(ArgumentError, /error:/)
    end
  end

  describe ".error_match?" do
    let(:boom) { RuntimeError.new("boom") }

    it "matches the absence of an error with false" do
      expect(described_class.error_match?(false, nil)).to be true
      expect(described_class.error_match?(false, boom)).to be false
    end

    it "matches the presence of any error with true" do
      expect(described_class.error_match?(true, boom)).to be true
      expect(described_class.error_match?(true, nil)).to be false
    end

    it "matches by exact class" do
      expect(described_class.error_match?(RuntimeError, boom)).to be true
      expect(described_class.error_match?(ArgumentError, boom)).to be false
    end

    it "matches by superclass (hierarchy, like rescue)" do
      expect(described_class.error_match?(StandardError, boom)).to be true
    end

    it "matches by mixin module on the error's class" do
      reportable = Module.new
      tagged = Class.new(StandardError) { include reportable }.new("tagged")
      expect(described_class.error_match?(reportable, tagged)).to be true
      expect(described_class.error_match?(reportable, boom)).to be false
    end

    it "matches a String against the error's own class name, never its ancestry" do
      expect(described_class.error_match?("RuntimeError", boom)).to be true
      expect(described_class.error_match?("StandardError", boom)).to be false
    end

    it "matches a Regexp against the error's own class name, never its ancestry" do
      expect(described_class.error_match?(/Runtime/, boom)).to be true
      expect(described_class.error_match?(/StandardError/, boom)).to be false
    end

    it "matches with a Proc receiving the error itself" do
      expect(described_class.error_match?(->(e) { e.message == "boom" }, boom)).to be true
      expect(described_class.error_match?(->(e) { e.message == "quiet" }, boom)).to be false
    end

    it "matches any element of an Array, mixing matcher kinds" do
      expect(described_class.error_match?([ArgumentError, /Runtime/], boom)).to be true
      expect(described_class.error_match?([ArgumentError, /Type/], boom)).to be false
    end

    it "matches nothing but false when no error is present (Procs are not even called)" do
      probe = ->(_) { raise "must not be called on nil" }
      aggregate_failures do
        expect(described_class.error_match?(true, nil)).to be false
        expect(described_class.error_match?(StandardError, nil)).to be false
        expect(described_class.error_match?("RuntimeError", nil)).to be false
        expect(described_class.error_match?(/anything/, nil)).to be false
        expect(described_class.error_match?(probe, nil)).to be false
        expect(described_class.error_match?([probe, true], nil)).to be false
      end
    end
  end

  describe ".matches? with the error: key" do
    let(:target_class) { Struct.new(:error, keyword_init: true) }

    it "routes error: through the bespoke matcher — a Regexp sees the class name" do
      # Under the generic layers this was the silent-no-match trap: a Regexp
      # never === an exception instance, and the name fallback needs a Class.
      hook = { filters: { error: /Runtime/ } }
      expect(described_class.matches?(hook, target_class.new(error: RuntimeError.new("boom")))).to be true
      expect(described_class.matches?(hook, target_class.new(error: nil))).to be false
    end

    it "expresses \"did not error\" with error: false" do
      hook = { filters: { error: false } }
      expect(described_class.matches?(hook, target_class.new(error: nil))).to be true
      expect(described_class.matches?(hook, target_class.new(error: RuntimeError.new("boom")))).to be false
    end
  end

  describe ".run" do
    after { described_class.reset! }

    let(:job) { build_test_job(type: "test") }

    it "calls matching hooks in FIFO order" do
      results = []
      Busybee.before_perform { results << :first }
      Busybee.before_perform { results << :second }

      described_class.run(:before_perform, job)
      expect(results).to eq(%i[first second])
    end

    it "passes the job to each hook" do
      received = nil
      Busybee.before_perform { |arg| received = arg }

      described_class.run(:before_perform, job)
      expect(received).to be(job)
    end

    it "does nothing when no hooks are registered" do
      expect { described_class.run(:before_perform, job) }.not_to raise_error
    end

    context "with safe: false (default, propagating)" do
      it "lets errors propagate" do
        Busybee.before_perform { raise "boom" }

        expect { described_class.run(:before_perform, job) }.to raise_error(RuntimeError, "boom")
      end

      it "stops at the first error" do
        results = []
        Busybee.before_perform { raise "boom" }
        Busybee.before_perform { results << :second }

        described_class.run(:before_perform, job) rescue nil # rubocop:disable Style/RescueModifier
        expect(results).to eq([])
      end
    end

    context "with safe: true (swallowing)" do
      it "swallows errors and continues to the next hook" do
        results = []
        Busybee.after_perform { raise "boom" }
        Busybee.after_perform { results << :second }

        described_class.run(:after_perform, job, safe: true)
        expect(results).to eq([:second])
      end

      it "logs swallowed errors with class, message, and source location" do
        logger = instance_double(Logger, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.after_perform { raise "boom" }

        described_class.run(:after_perform, job, safe: true)
        expect(logger).to have_received(:error).
          with(%r{\[busybee\] Error in hooks \(ignored\): \[RuntimeError\] boom \(at .+/hooks_spec\.rb:\d+})
      end

      it "always propagates Busybee::Worker::Shutdown" do
        Busybee.after_perform { raise Busybee::Worker::Shutdown.new(worker_class: nil) }

        expect do
          described_class.run(:after_perform, job, safe: true)
        end.to raise_error(Busybee::Worker::Shutdown)
      end

      it "propagates shutdown_on errors from worker class config" do
        worker_class = Class.new(Busybee::Worker) do
          def self.name = "DbGoneWorker"
          shutdown_on RuntimeError
        end
        job.set_context(worker: worker_class.allocate)
        Busybee.after_perform { raise "db gone" }

        expect do
          described_class.run(:after_perform, job, safe: true)
        end.to raise_error(Busybee::Worker::Shutdown) { |shutdown|
          # The raised Shutdown names the worker whose config triggered it.
          expect(shutdown.worker_class).to be(worker_class)
          expect(shutdown.message).to include("DbGoneWorker")
        }
      end

      it "propagates shutdown_on errors from gem-level config" do
        original = Busybee.shutdown_on_errors
        begin
          Busybee.shutdown_on_errors = [RuntimeError]
          Busybee.after_perform { raise "db gone" }

          expect do
            described_class.run(:after_perform, job, safe: true)
          end.to raise_error(Busybee::Worker::Shutdown)
        ensure
          Busybee.shutdown_on_errors = original
        end
      end
    end

    context "with prefiltering" do
      it "skips hooks whose filters do not match" do
        results = []
        Busybee.before_perform(status: :failed) { results << :filtered }
        Busybee.before_perform { results << :unfiltered }

        described_class.run(:before_perform, job) # event has status: :ready
        expect(results).to eq([:unfiltered])
      end

      it "resolves the buffered filter off the job (Job#buffered, not its negation)" do
        fired = []
        buffered_job = build_test_job(type: "test", key: 1).tap { |j| j.set_context(buffered: true) }
        unbuffered_job = build_test_job(type: "test", key: 2) # buffered? false
        Busybee.before_perform(buffered: true) { |job| fired << job.key }

        described_class.run(:before_perform, buffered_job)
        described_class.run(:before_perform, unbuffered_job)

        expect(fired).to eq([buffered_job.key])
      end
    end
  end

  describe ".run_chain" do
    after { described_class.reset! }

    let(:job) { build_test_job(type: "test") }

    it "calls the core block when no around hooks are registered" do
      called = false
      described_class.run_chain(:around_perform, job) { called = true }
      expect(called).to be true
    end

    it "wraps the core block with a single around hook" do
      results = []
      Busybee.around_perform do |_job, perform|
        results << :before
        perform.call
        results << :after
      end

      described_class.run_chain(:around_perform, job) { results << :core }
      expect(results).to eq(%i[before core after])
    end

    it "nests 3 hooks in FIFO order (outermost registered first)" do
      results = []
      %i[outer middle inner].each do |label|
        Busybee.around_perform do |_job, perform|
          results << :"#{label}_before"
          perform.call
          results << :"#{label}_after"
        end
      end

      described_class.run_chain(:around_perform, job) { results << :core }
      expect(results).to eq(%i[
                              outer_before middle_before inner_before
                              core
                              inner_after middle_after outer_after
                            ])
    end

    it "passes the job to each hook" do
      received = []
      Busybee.around_perform do |arg, perform|
        received << arg
        perform.call
      end

      described_class.run_chain(:around_perform, job) {} # rubocop:disable Lint/EmptyBlock
      expect(received).to eq([job])
    end

    it "captures the core block return value onto job.result (set-once + HWIA + freeze)" do
      result = described_class.run_chain(:around_perform, job) { { order_id: 123 } }
      expect(result).to eq("order_id" => 123)
      expect(job.result).to eq("order_id" => 123)
    end

    it "returns job.result even when middleware forgets to return it" do
      Busybee.around_perform do |_job, perform|
        perform.call
        "middleware forgot to return result"
      end

      result = described_class.run_chain(:around_perform, job) { { order_id: 123 } }
      expect(result).to eq("order_id" => 123)
    end

    it "freezes the captured result so it can't be mutated post-capture" do
      described_class.run_chain(:around_perform, job) { { order_id: 123 } }
      expect(job.result).to be_frozen
    end

    it "applies with_indifferent_access to the result" do
      described_class.run_chain(:around_perform, job) { { order_id: 123 } }
      expect(job.result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(job.result[:order_id]).to eq(123)
      expect(job.result["order_id"]).to eq(123)
    end

    it "leaves job.result nil when core returns non-Hash (Resolution rejects)" do
      result = described_class.run_chain(:around_perform, job) { nil }
      expect(result).to be_nil
      expect(job.result).to be_nil
    end

    it "lets errors from around hooks propagate" do
      Busybee.around_perform { |_job, _perform| raise "middleware boom" }

      expect do
        described_class.run_chain(:around_perform, job) { "core" }
      end.to raise_error(RuntimeError, "middleware boom")
    end

    it "lets errors from the core block propagate through middleware" do
      results = []
      Busybee.around_perform do |_job, perform|
        results << :before
        perform.call
      rescue RuntimeError
        results << :rescued
        raise
      end

      expect do
        described_class.run_chain(:around_perform, job) { raise "core boom" }
      end.to raise_error(RuntimeError, "core boom")
      expect(results).to eq(%i[before rescued])
    end

    context "with prefiltering" do
      it "excludes non-matching hooks from the chain" do
        results = []
        Busybee.around_perform(status: :failed) do |_job, perform|
          results << :filtered
          perform.call
        end
        Busybee.around_perform do |_job, perform|
          results << :unfiltered
          perform.call
        end

        described_class.run_chain(:around_perform, job) { results << :core }
        expect(results).to eq(%i[unfiltered core])
      end
    end

    context "with safe: true" do
      it "swallows hook error and still runs the core" do
        results = []
        Busybee.around_perform { |_job, _perform| raise "broken hook" }

        described_class.run_chain(:around_perform, job, safe: true) { results << :core }
        expect(results).to eq([:core])
      end

      it "does not double-run core when hook raises after calling process" do
        call_count = 0
        Busybee.around_perform do |_job, perform|
          perform.call
          raise "post-process error"
        end

        described_class.run_chain(:around_perform, job, safe: true) { call_count += 1 }
        expect(call_count).to eq(1)
      end

      it "logs swallowed errors with class, message, and source location" do
        logger = instance_double(Logger, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.around_perform { |_job, _perform| raise "broken" }

        described_class.run_chain(:around_perform, job, safe: true) { "core" }
        expect(logger).to have_received(:error).
          with(%r{\[busybee\] Error in hooks \(ignored\): \[RuntimeError\] broken \(at .+/hooks_spec\.rb:\d+})
      end

      it "always propagates Shutdown" do
        Busybee.around_perform { |_job, _perform| raise Busybee::Worker::Shutdown.new(worker_class: nil) }

        expect do
          described_class.run_chain(:around_perform, job, safe: true) { "core" }
        end.to raise_error(Busybee::Worker::Shutdown)
      end

      it "swallows outer hook but inner hook still wraps core" do
        results = []
        Busybee.around_perform { |_job, _perform| raise "outer broken" }
        Busybee.around_perform do |_job, perform|
          results << :inner_before
          perform.call
          results << :inner_after
        end

        described_class.run_chain(:around_perform, job, safe: true) { results << :core }
        expect(results).to eq(%i[inner_before core inner_after])
      end

      it "force-runs the core when an observing middleware returns without yielding" do
        results = []
        Busybee.around_perform { |_job, _perform| results << :hook } # never calls perform

        described_class.run_chain(:around_perform, job, safe: true) { results << :core }
        expect(results).to eq(%i[hook core])
      end

      it "warns when an observing middleware returns without yielding" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)
        Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

        described_class.run_chain(:around_perform, job, safe: true) { "core" }
        expect(logger).to have_received(:warn).
          with(/\[busybee\].*without yielding/)
      end

      it "does not double-run the core when a forced continuation raises" do
        call_count = 0
        Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

        described_class.run_chain(:around_perform, job, safe: true) do
          call_count += 1
          raise "core boom"
        end
        expect(call_count).to eq(1)
      end
    end
  end
end
