# frozen_string_literal: true

require "concurrent"

# A worker lifecycle hook at stop requested, stopping or shutdown failing in a
# way the process can't recover from, with a real client: nothing it raises
# leaves the worker or changes how the shutdown ends.
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

  shared_examples "a shutdown that finishes" do
    it "finishes the stop, reports the error at on_worker_shutdown and says to exit immediately" do
      raised, status = run_with_shutdown_status

      aggregate_failures do
        expect(raised).to be_nil
        expect([status&.reason, status&.error]).to match([expected_reason, an_instance_of(NoMemoryError)])
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end

  describe "at on_worker_stop_requested, on the thread asking for the stop" do
    let(:worker_class) { stopping_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
    let(:expected_reason) { :sigterm }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1), wire_job(2)])] }
      Busybee::Hooks.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it_behaves_like "a shutdown that finishes"

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
    let(:expected_reason) { :gateway_closed }

    before do
      gateway.on(:stream_activated_jobs) { [wire_job(1)] }
      Busybee::Hooks.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it_behaves_like "a shutdown that finishes"

    it "leaves the stream reader alive to finish, rather than dying by exception" do
      expect { run_to_completion }.not_to output(/terminated with exception/).to_stderr
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
    let(:expected_reason) { :sigterm }

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

    it_behaves_like "a shutdown that finishes"

    it "skips the drain" do
      run_to_completion

      expect(gateway.received(:fail_job)).to be_empty
    end
  end

  describe "at on_worker_shutdown" do
    let(:worker_class) { stopping_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1)])] }
      Busybee::Hooks.on_worker_shutdown { |_status| raise NoMemoryError, "failed to allocate memory" }
    end

    it "finishes the run and says to exit immediately" do
      aggregate_failures do
        expect(run_to_completion).to be_nil
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
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

    it "kills the other workers" do
      statuses = shutdown_statuses_from { expect(run_to_completion(seconds: 5)).to be_nil }

      expect(statuses.find { |status| status.worker_class == beta_class }&.reason).to eq(:crash)
    end
  end
end
