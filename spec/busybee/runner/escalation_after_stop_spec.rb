# frozen_string_literal: true

# A worker declared down after a stop has already claimed the reason, on the
# main thread of each receive path, with a real client. The stop finishes as
# the graceful stop it was, and reports the Shutdown rather than raising it.
RSpec.describe "an escalation on the main thread after a stop", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:stream_gate) { Queue.new }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  after { stream_gate.close }

  def corridor_worker(mode)
    corridor_runner = -> { runner }
    Class.new(Busybee::Worker) do
      job_type "escalation_after_stop"
      worker_mode mode

      define_method(:perform) do
        corridor_runner.call.stop!(reason: :signal)
        raise Busybee::Worker::Shutdown, "replica lag too high"
      end
    end
  end

  def wire_job(key = 1) = FaultInjectionGateway.activated_job(type: "escalation_after_stop", key: key)
  def deliver_by_poll = gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job])] }
  def hold_stream_open = gateway.on(:stream_activated_jobs) { Enumerator.new { |_| stream_gate.pop } }

  def deliver_by_stream
    gateway.on(:stream_activated_jobs) do
      Enumerator.new do |yielder|
        yielder << wire_job
        stream_gate.pop
      end
    end
  end

  shared_examples "a graceful stop that stands" do
    it "returns from the run, reporting the Shutdown at on_worker_shutdown under the stop's reason" do
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion }

      aggregate_failures do
        expect(raised).to be_nil
        expect([status.reason, status.error]).to match([:signal, an_instance_of(Busybee::Worker::Shutdown)])
        expect(runner.running?).to be(false)
      end
    end
  end

  describe "on a polling worker" do
    let(:worker_class) { corridor_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_poll }

    it_behaves_like "a graceful stop that stands"
  end

  # The job's own on_job_activated asks for the stop, then declares the worker
  # down; the job goes back to the engine unworked.
  describe "on a polling worker's activation" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "escalation_after_stop"
        worker_mode :polling

        def perform = {}
      end
    end

    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      deliver_by_poll
      stopping = -> { runner }
      Busybee.on_job_activated do |_job|
        stopping.call.stop!(reason: :signal)
        raise Busybee::Worker::Shutdown, "replica lag too high"
      end
    end

    it_behaves_like "a graceful stop that stands"

    it "hands the job back" do
      run_to_completion

      expect(gateway.received(:fail_job).map(&:jobKey)).to eq([1])
    end
  end

  describe "on a streaming worker's buffer consumer" do
    let(:worker_class) { corridor_worker(:streaming) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_stream }

    it_behaves_like "a graceful stop that stands"
  end

  describe "on an inline streaming worker" do
    let(:worker_class) { corridor_worker(:streaming) }
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_stream }

    it_behaves_like "a graceful stop that stands"
  end

  describe "on a hybrid worker draining its backlog" do
    let(:worker_class) { corridor_worker(:hybrid) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      hold_stream_open
      deliver_by_poll
    end

    it_behaves_like "a graceful stop that stands"
  end
end
