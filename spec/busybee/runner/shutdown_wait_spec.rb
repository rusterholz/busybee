# frozen_string_literal: true

require "concurrent"

# How long a worker's teardown waits on another thread's share of the
# shutdown, bounded by the process-wide shutdown_wait_timeout.
RSpec.describe "a worker waiting out its shutdown", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:release) { Concurrent::Event.new }
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "shutdown_wait"
      worker_mode :streaming

      def perform = {}
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }
  around { |example| with_shutdown_wait_timeout(200) { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:stream_activated_jobs) { [FaultInjectionGateway.activated_job(type: "shutdown_wait", key: 1)] }
  end

  after { release.set }

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # The gateway closes the stream, so the pump announces the stop, and its
  # on_worker_stop_requested hook holds the pump for 1.5s.
  describe "for a stream reader still busy when the worker drains" do
    before do
      held = release
      Busybee::Hooks.on_worker_stop_requested { |_status| held.wait(1.5) }
    end

    it "stops waiting after shutdown_wait_timeout" do
      raised = :unset
      took = elapsed { raised = run_to_completion }

      expect([raised, took]).to match([nil, be < 1.0])
    end
  end

  # A YAML file spells the knob as a String, which reaches the worker's own
  # runtime config unconverted.
  describe "given a runtime config carrying it as YAML spells it" do
    let(:runtime_config) { Busybee::RuntimeConfig.new(shutdown_wait_timeout: "5000").resolve_for(worker_class) }

    it "still finishes its shutdown" do
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion }

      aggregate_failures do
        expect(raised).to be_nil
        expect(status&.reason).to eq(:gateway_closed)
        expect(runner.running?).to be(false)
      end
    end
  end
end
