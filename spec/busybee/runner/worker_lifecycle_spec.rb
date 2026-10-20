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

  around { |example| isolate_busybee_hooks { example.run } }

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
    it "fires all four moments in order on a clean run with no stop signal" do
      record_all_lifecycle_hooks
      runner.run!
      expect(moments).to eq(%i[started stop_requested stopping shutdown])
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

  describe "#stop!(reason:), the caller-supplied stop reason" do
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

    it "records the reason once: the first stop! wins (set-once)" do
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

    # An adopter's filter raises while the hook is matched, outside the swallow.
    it "contains an ordinary error escaping a teardown hook's swallow, and finishes the shutdown" do
      captured = nil
      Busybee.on_worker_stopping(reason: ->(_reason) { raise "broken filter" }) { nil }
      Busybee.on_worker_shutdown { |worker| captured = worker }

      aggregate_failures do
        expect { runner.run! }.not_to raise_error
        expect(captured&.error).to be_a(RuntimeError).and(have_attributes(message: "broken filter"))
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(false)
      end
    end

    # The swallow logs the hook's error, and the log write fails too.
    def logger_failing_on_error
      Class.new do
        def info(_line) = nil
        def warn(_line) = nil
        def error(_line) = raise(IOError, "log device closed")
      end.new
    end

    it "finishes the shutdown when logging a teardown hook's swallowed error fails" do
      Busybee.logger = logger_failing_on_error
      captured = nil
      Busybee.on_worker_stopping { raise "broken hook" }
      Busybee.on_worker_shutdown { |worker| captured = worker }

      expect { runner.run! }.to output(/failed to log \(IOError: log device closed\): Error in hooks/).to_stderr
      aggregate_failures do
        expect(captured.error).to be_nil
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(false)
      end
    ensure
      Busybee.logger = nil
    end
  end

  # Once teardown has begun the worker cannot be made more stopped, so the
  # special meaning of Shutdown and shutdown_on is already satisfied and an
  # escalation from T1/T2/T3 buys nothing, while costing the rest of the
  # teardown. T0 is excluded: a start can still be aborted.
  describe "escalation from a shutting-down moment" do
    let(:runner_class) do
      Class.new(super()) do
        attr_reader :drained

        private

        def drain_on_shutdown = @drained = true
      end
    end

    it "lets the rest of the teardown run when on_worker_stopping declares unhealth" do
      record_all_lifecycle_hooks
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }

      expect { runner.run! }.not_to raise_error

      aggregate_failures do
        expect(moments).to eq(%i[started stop_requested stopping shutdown])
        expect(runner.drained).to be(true)
        expect(runner.running?).to be(false)
      end
    end

    # Were @running left set, the next run! would lose start!'s compare-and-set
    # and return having done nothing.
    it "leaves the runner able to run again" do
      isolate_busybee_hooks do
        Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }
        runner.run!
      end

      entered = false
      runner.test_run_loop = -> { entered = true }
      runner.run!

      expect(entered).to be(true)
    end

    it "does not replace the exception the worker was already exiting on" do
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }
      runner.test_run_loop = -> { raise "the original crash" }

      expect { runner.run! }.to raise_error(RuntimeError, "the original crash")
    end

    it "leaves the set-once stop reason alone" do
      captured = nil
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = -> { runner.stop!(reason: :rollover) } # stopping before run! would early-return
      runner.run!

      expect(captured.reason).to eq(:rollover)
    end

    it "hands the escalation to the shutdown observer, so it is not merely lost" do
      captured = nil
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.run!

      expect(captured.error).to be_a(Busybee::Worker::Shutdown)
    end

    # The exit exception is why the worker is going down; a hook's complaint
    # about it is not allowed to overwrite it on the carrier.
    it "keeps the exit exception on the carrier when there is one" do
      captured = nil
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_run_loop = -> { raise "the original crash" }
      begin
        runner.run!
      rescue RuntimeError # rubocop:disable Lint/SuppressedException
      end

      expect(captured.error).to be_a(RuntimeError)
    end

    it "says in the log that it declined to escalate, and why" do
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }

      lines = capture_busybee_log { runner.run! }

      expect(lines).to include("ERROR [busybee] Shutdown from on_worker_stopping ignored, LifecycleWorker already " \
                               "shutting down (Busybee::Worker::Shutdown: T2 declares unhealth)")
    end

    it "carries the worker and the escalation in JSON" do
      Busybee.on_worker_stopping { raise Busybee::Worker::Shutdown, "T2 declares unhealth" }

      lines = capture_busybee_log(format: :json) { runner.run! }

      expect(lines).to include(a_hash_including("worker_class" => "LifecycleWorker",
                                                "error_class" => "Busybee::Worker::Shutdown",
                                                "error_message" => "T2 declares unhealth"))
    end

    it "clears running? when on_worker_shutdown declares unhealth" do
      Busybee.on_worker_shutdown { raise Busybee::Worker::Shutdown, "T3 declares unhealth" }

      expect { runner.run! }.not_to raise_error
      expect(runner.running?).to be(false)
    end

    it "does not propagate out of stop! when on_worker_stop_requested declares unhealth" do
      Busybee.on_worker_stop_requested { raise Busybee::Worker::Shutdown, "T1 declares unhealth" }

      expect { runner.stop! }.not_to raise_error
      expect(runner.stopping?).to be(true)
    end

    it "still escalates from on_worker_started, where a start can be aborted" do
      Busybee.on_worker_started { raise Busybee::Worker::Shutdown, "T0 declares unhealth" }

      expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
    end

    context "with an error listed in shutdown_on" do
      before do
        stub_const("LifecycleFatal", Class.new(StandardError))
        Busybee.shutdown_on_errors = [LifecycleFatal]
      end

      after { Busybee.shutdown_on_errors = nil }

      it "escalates it from on_worker_started" do
        Busybee.on_worker_started { raise LifecycleFatal, "listed" }

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown) { |e| expect(e.cause).to be_a(LifecycleFatal) }
      end

      it "contains it at on_worker_stopping" do
        Busybee.on_worker_stopping { raise LifecycleFatal, "listed" }

        expect { runner.run! }.not_to raise_error
        expect(runner.running?).to be(false)
      end
    end
  end

  # The drain is the ensure's other door. A hook is the obvious way to blow up
  # mid-teardown, but a failing wire call or the pump join's re-raise does the
  # same damage, so the invariant is that run!'s ensure completes, short of an
  # error the process can't recover from, rather than that hook errors are contained.
  describe "the drain inside the teardown" do
    let(:runner_class) do
      Class.new(super()) do
        attr_writer :test_drain
        attr_reader :drained

        private

        def drain_on_shutdown
          @drained = true
          @test_drain&.call
        end
      end
    end

    it "finishes the teardown when the drain fails" do
      record_all_lifecycle_hooks
      runner.test_drain = -> { raise "the broker went away mid-drain" }

      expect { runner.run! }.not_to raise_error

      aggregate_failures do
        expect(moments).to eq(%i[started stop_requested stopping shutdown])
        expect(runner.running?).to be(false)
      end
    end

    it "says in the log that the drain failed, and how" do
      runner.test_drain = -> { raise "the broker went away mid-drain" }

      lines = capture_busybee_log { runner.run! }

      expect(lines).to eq(["ERROR [busybee] Drain failed during LifecycleWorker's shutdown, continuing the " \
                           "teardown (RuntimeError: the broker went away mid-drain)"])
    end

    it "hands the drain's failure to the shutdown observer" do
      captured = nil
      Busybee.on_worker_shutdown { |worker| captured = worker }
      runner.test_drain = -> { raise "the broker went away mid-drain" }
      runner.run!

      expect(captured.error).to be_a(RuntimeError)
    end

    it "runs the drain when the worker is exiting on an ordinary error" do
      runner.test_run_loop = -> { raise "an ordinary crash" }
      begin
        runner.run!
      rescue RuntimeError # rubocop:disable Lint/SuppressedException
      end

      expect(runner.drained).to be(true)
    end

    # N gRPC calls under memory exhaustion is how you make that worse. Dropping
    # the work is correct here: the engine re-yields it after the activation
    # times out, and the process is not going to survive to do it itself.
    it "skips the drain when the worker is exiting on something it cannot recover from" do
      runner.test_run_loop = -> { raise NoMemoryError, "out of memory" }

      expect { runner.run! }.to raise_error(NoMemoryError)
      expect(runner.drained).to be_falsey
    end

    it "still fires the stop announcement and both closing moments on that path" do
      record_all_lifecycle_hooks
      runner.test_run_loop = -> { raise NoMemoryError, "out of memory" }
      begin
        runner.run!
      rescue NoMemoryError # rubocop:disable Lint/SuppressedException
      end

      expect(moments).to eq(%i[started stop_requested stopping shutdown])
    end

    it "raises a drain's unrecoverable failure out of run!, skipping on_worker_shutdown, and says to exit" do
      record_all_lifecycle_hooks
      runner.test_drain = -> { raise NoMemoryError, "out of memory mid-drain" }

      aggregate_failures do
        expect { runner.run! }.to raise_error(NoMemoryError, "out of memory mid-drain")
        expect(moments).to eq(%i[started stop_requested stopping])
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
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
