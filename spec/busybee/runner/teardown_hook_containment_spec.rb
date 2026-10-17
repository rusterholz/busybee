# frozen_string_literal: true

require "concurrent"

# A worker lifecycle hook at stop requested, stopping or shutdown failing in a
# way the process can't recover from, with a real client: the process must exit
# immediately, and the error leaves the thread the hook ran on, except the stream
# reader's, which reports it at on_worker_shutdown.
RSpec.describe "an unrecoverable error from a teardown hook", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:stream_gate) { Queue.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  after { stream_gate.close }

  def wire_job(key, type = "teardown_hooks") = FaultInjectionGateway.activated_job(type: type, key: key)

  def stopping_worker(mode)
    corridor_runner = -> { runner }
    Class.new(Busybee::Worker) do
      job_type "teardown_hooks"
      worker_mode mode

      define_method(:perform) do
        corridor_runner.call.stop!(reason: :sigterm)
        {}
      end
    end
  end

  def run_with_shutdown_status
    raised = :unset
    status = shutdown_status_from { raised = run_to_completion }
    [raised, status]
  end

  shared_examples "a crash out of the run" do
    it "raises the error out of run! and says to exit immediately" do
      raised = run_to_completion

      aggregate_failures do
        expect(raised).to be_an_instance_of(NoMemoryError)
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end

  describe "at on_worker_stop_requested, on the thread asking for the stop" do
    let(:worker_class) { stopping_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1), wire_job(2)])] }
      Busybee::Hooks.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it_behaves_like "a crash out of the run"

    it "reports the error at on_worker_shutdown, the run ending on it" do
      _raised, status = run_with_shutdown_status

      expect([status&.reason, status&.error]).to match([:sigterm, an_instance_of(NoMemoryError)])
    end

    it "hands back nothing, the batch's next job included" do
      run_to_completion

      expect(gateway.received(:fail_job)).to be_empty
    end
  end

  # The gateway ends the stream, so the stream reader announces the stop.
  describe "at on_worker_stop_requested, on a streaming worker's stream reader" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "teardown_hooks"
        worker_mode :streaming

        def perform = {}
      end
    end

    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:stream_activated_jobs) { [wire_job(1)] }
      Busybee::Hooks.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it "finishes the stop, reports the error at on_worker_shutdown and says to exit immediately" do
      raised, status = run_with_shutdown_status

      aggregate_failures do
        expect(raised).to be_nil
        expect([status&.reason, status&.error]).to match([:gateway_closed, an_instance_of(NoMemoryError)])
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end

    it "leaves the stream reader alive to finish, rather than dying by exception" do
      expect { run_to_completion }.not_to output(/terminated with exception/).to_stderr
    end

    # The stream fails instead, so the stop the reader announces is its own error's.
    context "when the stream fails" do
      before { gateway.on(:stream_activated_jobs) { Enumerator.new { |_| raise GRPC::Unavailable, "broker went away" } } }

      it "ends the run on the stream's error, rather than the stream reader dying of the hook's" do
        raised = nil
        status = nil
        run = -> { status = shutdown_status_from { raised = run_to_completion } }
        expect(&run).not_to output(/terminated with exception/).to_stderr

        aggregate_failures do
          expect(raised).to be_a(Busybee::GRPC::Error)
          expect([status&.reason, status&.error]).to match([:gateway_error, be(raised)])
          expect(Busybee::Runner.exit_immediately?).to be(true)
        end
      end
    end
  end

  # Job 1 stops the worker once job 2 is waiting in the buffer.
  describe "at on_worker_stopping, with a job still buffered" do
    let(:worker_class) do
      corridor_runner = -> { runner }
      Class.new(Busybee::Worker) do
        job_type "teardown_hooks"
        worker_mode :streaming

        define_method(:perform) do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep 0.005 until corridor_runner.call.send(:current_buffer_size) == 1 ||
                            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          corridor_runner.call.stop!(reason: :sigterm)
          {}
        end
      end
    end
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          yielder << wire_job(2)
          gate.pop
        end
      end
      Busybee::Hooks.on_worker_stopping { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it_behaves_like "a crash out of the run"

    it "skips the drain and the rest of the shutdown" do
      _raised, status = run_with_shutdown_status

      aggregate_failures do
        expect(gateway.received(:fail_job)).to be_empty
        expect(status).to be_nil
      end
    end
  end

  describe "at on_worker_shutdown" do
    let(:worker_class) { stopping_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1)])] }
      Busybee::Hooks.on_worker_shutdown { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it_behaves_like "a crash out of the run"
  end

  # Alpha's stream closes cleanly and its stopping hook fails; beta is idle.
  describe "in one worker of a multi-worker process" do
    let(:alpha_class) do
      stub_const("AlphaWorker", Class.new(Busybee::Worker) do
        job_type "alpha"
        worker_mode :streaming

        def perform = {}
      end)
    end

    let(:beta_class) do
      stub_const("BetaWorker", Class.new(Busybee::Worker) do
        job_type "beta"
        worker_mode :polling

        def perform = {}
      end)
    end

    let(:runner) { Busybee::Runner::Multi.new([alpha_class, beta_class], client: gateway.client) }

    before do
      gateway.on(:stream_activated_jobs) { [wire_job(1, "alpha")] }
      gateway.on(:activate_jobs) do
        sleep 0.05
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
      end
      Busybee::Hooks.on_worker_stopping(worker_class: "AlphaWorker") do |_status|
        raise NoMemoryError, "failed to allocate memory"
      end
    end

    it "kills the other workers and raises the error out of the process's run" do
      raised = nil
      statuses = shutdown_statuses_from { raised = run_to_completion(seconds: 5) }

      aggregate_failures do
        expect(raised).to be_an_instance_of(NoMemoryError)
        expect(statuses.find { |status| status.worker_class == beta_class }&.reason).to eq(:crash)
      end
    end
  end

  # A signal's thread asks every worker to stop; the first worker's stop
  # requested hook fails there, before the other hears of the stop. That other
  # waits on an idle stream's buffer, so nothing but a stop wakes it.
  describe "at on_worker_stop_requested, on a multi-worker process's signal thread" do
    let(:worker_classes) do
      { "alpha" => :polling, "beta" => :streaming }.map do |type, mode|
        Class.new(Busybee::Worker) do
          job_type type
          worker_mode mode

          def perform = {}
        end
      end
    end

    let(:runner) { Busybee::Runner::Multi.new(worker_classes, client: gateway.client) }
    let(:started) { Concurrent::CountDownLatch.new(2) }

    before do
      gateway.on(:activate_jobs) do
        sleep 0.05
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
      end
      gate = stream_gate
      gateway.on(:stream_activated_jobs) { Enumerator.new { |_| gate.pop } }
      latch = started
      alpha_class = worker_classes.first
      Busybee::Hooks.on_worker_started { |status| latch.count_down if status.worker_class == alpha_class }
      runner.runners.last.singleton_class.prepend(Module.new do
        define_method(:process_buffered_jobs) do |**options|
          latch.count_down
          super(**options)
        end
      end)
      Busybee::Hooks.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it "still ends every worker, raising the error on both threads" do
      signal_thread = Thread.new do
        Thread.current.report_on_exception = false
        started.wait(5)
        runner.stop!(reason: :sigterm)
      end
      raised = run_to_completion(seconds: 5)

      aggregate_failures do
        expect(started.count).to eq(0)
        expect(raised).to be_an_instance_of(NoMemoryError)
        expect { signal_thread.join(1) }.to raise_error(NoMemoryError)
        expect(runner.runners.map(&:running?)).to eq([false, false])
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end
end
