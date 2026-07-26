# frozen_string_literal: true

require "concurrent"

# Unit coverage for the worker-lifecycle wiring that Runner#run! / #stop! own:
# the four moments (started → stop_requested → stopping → shutdown), each firing
# its on_worker_* hook with a fresh Worker::Status carrier. Exercised through a
# minimal concrete Runner subclass so the template-method lifecycle is tested in
# isolation from the Polling/Streaming I/O.
RSpec.describe "Busybee::Runner worker lifecycle" do # rubocop:disable RSpec/DescribeClass
  let(:client) { instance_double(Busybee::Client) }

  let(:worker_class) do
    stub_const("LifecycleWorker", Class.new(Busybee::Worker) do
      job_type "lifecycle_worker"
      def perform; end
    end)
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new(worker_mode: :polling).resolve_for(worker_class) }

  # Minimal concrete runner: run_loop runs an injected body (default: a clean
  # return). Lets a test pick a clean stop, a block-until-stopped loop, or a
  # raising loop with zero gRPC plumbing.
  let(:runner_class) do
    Class.new(Busybee::Runner) do
      attr_writer :test_run_loop

      private

      def run_loop
        @test_run_loop&.call
      end
    end
  end

  let(:runner) { runner_class.new(worker_class, runtime_config: runtime_config, client: client) }
  let(:events) { Concurrent::Array.new }

  after { Busybee::Hooks.reset! }

  def record_all_lifecycle_hooks
    %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown].each do |type|
      moment = type.to_s.delete_prefix("on_worker_").to_sym
      Busybee.public_send(type) { |worker| events << [moment, worker] }
    end
  end

  def moments = events.map(&:first)

  def wait_until(timeout: 2, poll: 0.005)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end

  describe "firing order" do
    it "fires started → stopping → shutdown on a clean run (no stop signal)" do
      record_all_lifecycle_hooks
      runner.run!
      expect(moments).to eq(%i[started stopping shutdown])
    end

    it "fires all four moments, started first and shutdown last, when stopped mid-loop" do
      record_all_lifecycle_hooks
      runner.test_run_loop = -> { sleep 0.005 until runner.stopping? }
      thread = Thread.new { runner.run! }
      wait_until { moments.include?(:started) }
      runner.stop!
      thread.join(2)

      # stop_requested fires on the stopping thread and races stopping/shutdown
      # on the runner thread, so only the runner-thread order is deterministic.
      aggregate_failures do
        expect(moments).to contain_exactly(:started, :stop_requested, :stopping, :shutdown)
        expect(moments.first).to eq(:started)
        expect(moments.index(:started)).to be < moments.index(:stopping)
        expect(moments.index(:stopping)).to be < moments.index(:shutdown)
      end
    end
  end

  describe "#stop! and on_worker_stop_requested" do
    it "fires on_worker_stop_requested exactly once across repeated stop!" do
      record_all_lifecycle_hooks
      runner.stop!
      runner.stop!
      expect(moments).to eq(%i[stop_requested])
    end

    it "fires nothing else when stop! precedes run! (early return, sequence guard)" do
      record_all_lifecycle_hooks
      runner.stop!   # fires stop_requested
      runner.run!    # stopping? -> early return; started/stopping/shutdown must not fire
      expect(moments).to eq(%i[stop_requested])
    end
  end

  describe "#stop!(reason:) — the caller-supplied stop reason" do
    it "carries a caller-supplied reason onto on_worker_stop_requested" do
      captured = nil
      Busybee.on_worker_stop_requested { |worker| captured = worker }
      runner.stop!(reason: :rollover)
      expect(captured.reason).to eq(:rollover)
    end

    it "defaults the reason to :signal" do
      captured = nil
      Busybee.on_worker_stop_requested { |worker| captured = worker }
      runner.stop!
      expect(captured.reason).to eq(:signal)
    end

    it "rejects a non-symbol reason" do
      expect { runner.stop!(reason: "rollover") }.to raise_error(ArgumentError, /symbol/i)
    end

    it "records the reason once — the first stop! wins (set-once)" do
      reasons = Concurrent::Array.new
      Busybee.on_worker_stop_requested { |worker| reasons << worker.reason }
      runner.stop!(reason: :rollover)
      runner.stop!(reason: :sigterm)
      expect(reasons).to eq(%i[rollover])
    end
  end

  describe "#kill!" do
    it "stops with reason :kill" do
      captured = nil
      Busybee.on_worker_stop_requested { |worker| captured = worker }
      runner.kill!
      expect(captured.reason).to eq(:kill)
    end
  end

  describe "the Worker::Status carrier" do
    it "hands each hook a frozen Worker::Status with identity + timing" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.run!

      aggregate_failures do
        expect(captured).to be_a(Busybee::Worker::Status)
        expect(captured).to be_frozen
        expect(captured.worker_class).to be(worker_class)
        expect(captured.worker_mode).to eq(:polling)
        expect(captured.job_type).to eq("lifecycle_worker")
        expect(captured.worker_name).to eq(Busybee.worker_name)
        expect(captured.started_at).to be_a(Time)
        expect(captured.shutdown_at).to be_a(Time)
        expect(captured.uptime_s).to be_a(Float)
      end
    end

    it "reports a not-yet-reached moment as nil (snapshot semantics)" do
      captured = nil
      Busybee.on_worker_started { |worker| captured = worker }
      runner.run!

      aggregate_failures do
        expect(captured.started_at).to be_a(Time)
        expect(captured.stopping_at).to be_nil
        expect(captured.shutdown_at).to be_nil
      end
    end
  end

  describe "reason / error resolution (in the ensure)" do
    it "reports a stop we were told to make as :signal (stop!'s default), no error" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = -> { sleep 0.005 until runner.stopping? }
      thread = Thread.new { runner.run! }
      wait_until { runner.running? }
      runner.stop! # default reason
      thread.join(2)

      aggregate_failures do
        expect(captured.reason).to eq(:signal)
        expect(captured.error).to be_nil
      end
    end

    it "keeps an explicit stop reason through to shutdown" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = -> { sleep 0.005 until runner.stopping? }
      thread = Thread.new { runner.run! }
      wait_until { runner.running? }
      runner.stop!(reason: :rollover)
      thread.join(2)

      expect(captured.reason).to eq(:rollover)
    end

    it "reports an unhandled non-gRPC error as :crash, carrying the exception, and re-raises" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      boom = RuntimeError.new("boom")
      runner.test_run_loop = -> { raise boom }

      expect { runner.run! }.to raise_error(boom)
      aggregate_failures do
        expect(captured.reason).to eq(:crash)
        expect(captured.error).to be(boom)
        expect(captured.error_message).to eq("boom")
      end
    end

    it "reports an unrecovered gRPC error as :gateway_error" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      grpc = Busybee::GRPC::Error.new("gateway down")
      runner.test_run_loop = -> { raise grpc }

      expect { runner.run! }.to raise_error(grpc)
      aggregate_failures do
        expect(captured.reason).to eq(:gateway_error)
        expect(captured.error).to be(grpc)
      end
    end

    it "lets an explicit reason win over a coexisting exit error (reason ⊥ error)" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = lambda do
        runner.stop!(reason: :rollover)
        raise "drain blew up"
      end

      expect { runner.run! }.to raise_error("drain blew up")
      aggregate_failures do
        expect(captured.reason).to eq(:rollover)       # the trigger stands
        expect(captured.error).to be_a(RuntimeError)   # the outcome rides its own axis
        expect(captured.error.message).to eq("drain blew up")
      end
    end

    it "unwraps a Worker::Shutdown to its triggering cause on the error axis" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = lambda do
        raise "underlying"
      rescue RuntimeError
        raise Busybee::Worker::Shutdown.new(worker_class: LifecycleWorker)
      end

      expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
      aggregate_failures do
        expect(captured.error).to be_a(RuntimeError)   # error axis = the triggering cause
        expect(captured.error.message).to eq("underlying")
        expect(captured.reason).to eq(:unhealthy)      # a Worker::Shutdown = the worker declared itself down
      end
    end
  end

  describe "lifecycle durations" do
    it "computes stop_latency_ms and stop_duration_ms after a signalled stop" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = -> { sleep 0.005 until runner.stopping? }
      thread = Thread.new { runner.run! }
      wait_until { runner.running? } # the loop is live; stop! now yields a real latency
      runner.stop!
      thread.join(2)

      aggregate_failures do
        expect(captured.stop_latency_ms).to be_a(Float)   # T2 - T1
        expect(captured.stop_duration_ms).to be_a(Float)  # T3 - T2
        expect(captured.stop_duration_ms).to be >= 0
      end
    end
  end

  describe "filter matching on the Worker::Status carrier" do
    it "fires only the hook whose worker_mode filter matches the Status" do
      fired = []
      Busybee.on_worker_shutdown(worker_mode: :polling) { fired << :polling }
      Busybee.on_worker_shutdown(worker_mode: :streaming) { fired << :streaming }
      runner.run!
      expect(fired).to eq([:polling])
    end

    it "fires only the hook whose reason filter matches the outcome" do
      fired = []
      Busybee.on_worker_shutdown(reason: :crash) { fired << :crash }
      Busybee.on_worker_shutdown(reason: :signal) { fired << :signal }
      runner.test_run_loop = -> { sleep 0.005 until runner.stopping? }
      thread = Thread.new { runner.run! }
      wait_until { runner.running? }
      runner.stop! # default :signal
      thread.join(2)
      expect(fired).to eq([:signal])
    end
  end

  describe "observation-only safety" do
    it "swallows a StandardError raised from a worker hook" do
      Busybee.on_worker_started { raise "broken hook" }
      expect { runner.run! }.not_to raise_error
    end
  end

  describe "single-entry guard (no concurrent / repeated run!)" do
    it "rejects a second run! while already running, without re-entering the loop" do
      loop_entries = Concurrent::AtomicFixnum.new(0)
      runner.test_run_loop = lambda do
        loop_entries.increment
        sleep 0.005 until runner.stopping?
      end
      active = Thread.new { runner.run! }
      wait_until { runner.running? }

      second = Thread.new { runner.run! }

      aggregate_failures do
        expect(second.join(0.5)).to be_truthy # rejected entry returns at once, no run loop
        expect(loop_entries.value).to eq(1)   # the loop was entered exactly once
        expect(runner.running?).to be(true)   # the rejected entry didn't clear the active run
      end

      runner.stop!
      active.join(2)
    end
  end
end
