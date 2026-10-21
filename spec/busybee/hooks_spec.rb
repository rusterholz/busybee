# frozen_string_literal: true

require "busybee/hooks"
require "busybee/testing"

RSpec.describe Busybee::Hooks do
  around { |example| isolate_busybee_hooks { example.run } }

  describe "hook storage" do
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
      expect(described_class::HOOK_NOUN.values.uniq).to match_array(Busybee::Hooks::Filters::FILTERS.keys)
    end
  end

  describe "registration" do
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

  describe "filter kwargs validation" do
    let(:noop) { proc { |_| "registered" } }

    it "accepts valid job filter kwargs" do
      expect do
        Busybee.after_perform(job_type: "test", worker_class: /Order/, status: :failed,
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
        Busybee.on_worker_shutdown(worker_class: /Order/, job_type: "test",
                                   worker_mode: :polling, reason: :crash,
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
        Busybee.after_call(rpc: :complete_job, status: :errored, grpc_status: :ok,
                           error: "Busybee::GRPC::Error", &noop)
      end.not_to raise_error
    end

    it "rejects unknown call filter kwargs" do
      expect do
        Busybee.before_call(job_type: "test", &noop)
      end.to raise_error(ArgumentError, /job_type/)
    end

    it "rejects error_class: as a filter on every noun, though each carrier reads it (error: filters)" do
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

  describe ".run" do
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
        Busybee.after_perform { raise "boom" }

        lines = capture_busybee_log { described_class.run(:after_perform, job, safe: true) }
        expect(lines).to contain_exactly(
          %r{\AERROR \[busybee\] Ignoring error raised by a hook, at .+/hooks_spec\.rb:\d+:in .+ \(RuntimeError: boom\)\z} # rubocop:disable Layout/LineLength
        )
      end

      it "carries the hook's target and the error in JSON" do
        Busybee.after_perform { raise "boom" }

        lines = capture_busybee_log(format: :json) { described_class.run(:after_perform, job, safe: true) }
        expect(lines.first).to include("job_key" => job.key, "error_class" => "RuntimeError", "error_message" => "boom",
                                       "error_location" => a_string_matching(/hooks_spec\.rb:\d+/))
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
        Busybee.before_perform(job_type: "some_other_type") { results << :filtered }
        Busybee.before_perform { results << :unfiltered }

        described_class.run(:before_perform, job) # job_type: "test"
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

    [false, true].each do |safe|
      it "hands every hook the core's value from perform.call, whatever the hooks return (safe: #{safe})" do
        returned = []
        %i[outer inner].each do |label|
          Busybee.around_perform do |_job, perform|
            returned << [label, perform.call]
            "#{label} hook's own value"
          end
        end

        described_class.run_chain(:around_perform, job, safe: safe) { :core_value }
        expect(returned).to eq([%i[inner core_value], %i[outer core_value]])
      end

      it "hands the core's value up past a hook that never yielded (safe: #{safe})" do
        returned = nil
        Busybee.around_perform { |_job, perform| returned = perform.call }
        Busybee.around_perform { |_job, _perform| :never_yielded }

        described_class.run_chain(:around_perform, job, safe: safe) { :core_value }
        expect(returned).to eq(:core_value)
      end
    end

    it "returns nil and leaves a Job carrier's result alone, whatever the core returns" do
      expect(described_class.run_chain(:around_perform, job) { { order_id: 123 } }).to be_nil
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

    # The chain always descends: there is one way to short-circuit a job, and
    # it is to resolve it. A middleware that forgets to yield can't cancel the
    # work; it just gets a warning and the work runs anyway.
    it "force-runs the core when a propagating middleware returns without yielding" do
      results = []
      Busybee.around_perform { |_job, _perform| results << :hook } # never calls perform

      described_class.run_chain(:around_perform, job) { results << :core }
      expect(results).to eq(%i[hook core])
    end

    it "warns when a propagating middleware returns without yielding" do
      Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

      lines = capture_busybee_log { described_class.run_chain(:around_perform, job) { "core" } }
      expect(lines).to contain_exactly(
        %r{\AWARN \[busybee\] Forcing continuation past an around-hook that returned without yielding \(at .+/hooks_spec\.rb:\d+\)\z} # rubocop:disable Layout/LineLength
      )
    end

    it "carries the chain's target in JSON" do
      Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

      lines = capture_busybee_log(format: :json) { described_class.run_chain(:around_perform, job) { "core" } }
      expect(lines.first).to include("job_key" => job.key, "level" => "warn")
    end

    it "still lets a propagating middleware abort by raising" do
      results = []
      Busybee.around_perform { |_job, _perform| raise "abort" }

      expect do
        described_class.run_chain(:around_perform, job) { results << :core }
      end.to raise_error(RuntimeError, "abort")
      expect(results).to eq([])
    end

    context "with prefiltering" do
      it "excludes non-matching hooks from the chain" do
        results = []
        Busybee.around_perform(job_type: "some_other_type") do |_job, perform|
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
        Busybee.around_perform { |_job, _perform| raise "broken" }

        lines = capture_busybee_log { described_class.run_chain(:around_perform, job, safe: true) { "core" } }
        expect(lines).to contain_exactly(
          %r{\AERROR \[busybee\] Ignoring error raised by a hook, at .+/hooks_spec\.rb:\d+:in .+ \(RuntimeError: broken\)\z} # rubocop:disable Layout/LineLength
        )
      end

      # safe: describes hook-error policy. An error raised by the work the hook
      # descended into is not the hook engine's to judge: it travels on, and it
      # is never reported as a hook's failure.
      it "does not swallow or misattribute an error raised by the core" do
        Busybee.around_perform { |_job, perform| perform.call }

        lines = capture_busybee_log do
          expect do
            described_class.run_chain(:around_perform, job, safe: true) { raise "core boom" }
          end.to raise_error(RuntimeError, "core boom")
        end
        expect(lines.grep(/Ignoring error raised by a hook/)).to be_empty
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
        Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

        lines = capture_busybee_log { described_class.run_chain(:around_perform, job, safe: true) { "core" } }
        expect(lines).to contain_exactly(/\AWARN \[busybee\] Forcing continuation past an around-hook that returned/)
      end

      it "does not double-run the core when a forced continuation raises" do
        call_count = 0
        Busybee.around_perform { |_job, _perform| } # rubocop:disable Lint/EmptyBlock

        expect do
          described_class.run_chain(:around_perform, job, safe: true) do
            call_count += 1
            raise "core boom"
          end
        end.to raise_error(RuntimeError, "core boom")
        expect(call_count).to eq(1)
      end

      # The classification boundary sits beneath the links, so it is there even
      # when nothing registered one. Without it, a worker's own shutdown_on
      # declaration held only while some unrelated hook happened to be listening.
      it "escalates a shutdown_on error raised by the core, with no hooks registered" do
        worker_class = Class.new(Busybee::Worker) do
          def self.name = "CoreFatalWorker"
          shutdown_on RuntimeError
        end
        job.set_context(worker: worker_class.allocate)

        expect do
          described_class.run_chain(:around_job_execution, job, safe: true) { raise "db gone" }
        end.to raise_error(Busybee::Worker::Shutdown)
      end

      it "escalates shutdown_on errors from worker class config to Shutdown" do
        worker_class = Class.new(Busybee::Worker) do
          def self.name = "DbGoneWorker"
          shutdown_on RuntimeError
        end
        job.set_context(worker: worker_class.allocate)
        Busybee.around_perform { |_job, _perform| raise "db gone" }

        expect do
          described_class.run_chain(:around_perform, job, safe: true) { "core" }
        end.to raise_error(Busybee::Worker::Shutdown) { |shutdown|
          expect(shutdown.worker_class).to be(worker_class)
          expect(shutdown.cause).to be_a(RuntimeError)
        }
      end

      it "escalates shutdown_on errors from gem-level config to Shutdown" do
        original = Busybee.shutdown_on_errors
        begin
          Busybee.shutdown_on_errors = [RuntimeError]
          Busybee.around_perform { |_job, _perform| raise "db gone" }

          expect do
            described_class.run_chain(:around_perform, job, safe: true) { "core" }
          end.to raise_error(Busybee::Worker::Shutdown)
        ensure
          Busybee.shutdown_on_errors = original
        end
      end

      it "does not run the core when a pre-yield hook error escalates" do
        results = []
        worker_class = Class.new(Busybee::Worker) do
          def self.name = "DbGoneWorker"
          shutdown_on RuntimeError
        end
        job.set_context(worker: worker_class.allocate)
        Busybee.around_perform { |_job, _perform| raise "db gone before yield" }

        expect do
          described_class.run_chain(:around_perform, job, safe: true) { results << :core }
        end.to raise_error(Busybee::Worker::Shutdown)
        # A declared-fatal error stops the work, unlike an ordinary swallow,
        # which force-runs the core so an observer can't cancel it.
        expect(results).to eq([])
      end
    end
  end
end
