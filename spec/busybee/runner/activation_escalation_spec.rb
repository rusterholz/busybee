# frozen_string_literal: true

require "concurrent"

# on_job_activated declaring the worker unhealthy, on each receive path, with a
# real client. The job it fired for is in hand and was never worked, so it goes
# back the way any job in hand at a shutdown does.
RSpec.describe "an escalation from on_job_activated", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:handed_back) { Concurrent::Array.new }
  let(:stream_gate) { Queue.new }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    Busybee::Hooks.on_job_not_executed { |job| handed_back << job }
  end

  after { stream_gate.close }

  def corridor_worker(mode, **streaming)
    Class.new(Busybee::Worker) do
      job_type "activation_escalation"
      worker_mode mode
      fail_job_backoff 1234
      streaming(**streaming) if streaming.any?

      def perform; end
    end
  end

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "activation_escalation", key: key, retries: 4)

  def deliver_by_poll
    gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1)])] }
  end

  def deliver_by_stream
    gateway.on(:stream_activated_jobs) do
      Enumerator.new do |yielder|
        yielder << wire_job(1)
        stream_gate.pop
      end
    end
  end

  def hold_stream_open = gateway.on(:stream_activated_jobs) { Enumerator.new { |_| stream_gate.pop } }

  shared_examples "a job handed back on escalation" do
    # Registered ahead of the escalating hook, which ends that moment's run.
    let!(:brackets) { record_job_brackets }

    before { Busybee::Hooks.on_job_activated { raise Busybee::Worker::Shutdown, "replica lag too high" } }

    it "sends the job back unworked, retries and backoff intact" do
      run_to_completion

      expect(gateway.received(:fail_job).map { |sent| [sent.jobKey, sent.retries, sent.retryBackOff] }).
        to eq([[1, 4, 1234]])
      expect(gateway.received(:complete_job)).to be_empty
    end

    it "closes the activation at on_job_not_executed, the job still :ready" do
      run_to_completion

      expect(brackets).to eq([[:activated, 1], [:not_executed, 1]])
      expect(handed_back.map { |job| [job.status, job.error] }).to eq([[:ready, nil]])
    end

    it "hands it back as a worker already stopping for being unhealthy" do
      run_to_completion

      expect(handed_back.map { |job| job.worker_status.reason }).to eq([:unhealthy])
    end

    it "still ends the worker on the escalation" do
      raised = nil
      status = shutdown_status_from { raised = run_to_completion }

      expect(raised).to be_a(Busybee::Worker::Shutdown)
      expect(status.reason).to eq(:unhealthy)
    end
  end

  describe "on a polling worker" do
    let(:worker_class) { corridor_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_poll }

    it_behaves_like "a job handed back on escalation"

    context "when the escalation is a shutdown_on match" do
      before do
        stub_const("ReplicaLagging", Class.new(StandardError))
        Busybee.shutdown_on_errors = [ReplicaLagging]
        Busybee::Hooks.on_job_activated { raise ReplicaLagging, "replica lag too high" }
      end

      after { Busybee.shutdown_on_errors = nil }

      it "hands the job back the same way" do
        expect(run_to_completion).to be_a(Busybee::Worker::Shutdown)
        expect(gateway.received(:fail_job).map(&:jobKey)).to eq([1])
      end
    end

    context "when the hook raises an error the worker cannot recover from" do
      before { Busybee::Hooks.on_job_activated { raise NoMemoryError, "failed to allocate memory" } }

      it "drops the job for the engine to reclaim, telling it nothing" do
        expect(run_to_completion).to be_a(NoMemoryError)
        expect(gateway.received(:fail_job)).to be_empty
        expect(handed_back).to be_empty
      end
    end
  end

  describe "on a streaming worker reading inline" do
    let(:worker_class) { corridor_worker(:streaming, buffer: false) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_stream }

    it_behaves_like "a job handed back on escalation"
  end

  describe "on a streaming worker's pump" do
    let(:worker_class) { corridor_worker(:streaming) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_stream }

    it_behaves_like "a job handed back on escalation"

    # The stop wakes the main thread before a slow on_worker_stop_requested
    # finishes on the pump, so the escalation has to be on record by then.
    context "when on_worker_stop_requested is slow" do
      before do
        Busybee::Hooks.on_worker_stop_requested { sleep 0.2 }
        Busybee::Hooks.on_job_activated { raise Busybee::Worker::Shutdown, "replica lag too high" }
      end

      it "ends the worker on the escalation from on_worker_stopping onward" do
        stopping = nil
        Busybee::Hooks.on_worker_stopping { |status| stopping = status }

        expect(run_to_completion).to be_a(Busybee::Worker::Shutdown)
        expect([stopping.reason, stopping.error]).to match([:unhealthy, an_instance_of(Busybee::Worker::Shutdown)])
      end
    end
  end

  describe "on a hybrid worker draining its backlog" do
    let(:worker_class) { corridor_worker(:hybrid) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      hold_stream_open
      deliver_by_poll
    end

    it_behaves_like "a job handed back on escalation"
  end
end
