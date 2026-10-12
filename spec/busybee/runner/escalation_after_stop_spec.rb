# frozen_string_literal: true

require "concurrent"

# perform declaring the worker down after a stop has already claimed the
# reason, on the main thread of each receive path that has one, with a real
# client. The stop's reason stands, and the run still ends on the Shutdown.
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

  def wire_job = FaultInjectionGateway.activated_job(type: "escalation_after_stop", key: 1)
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

  shared_examples "an escalation kept to raise" do
    it "ends the run on the Shutdown, under the reason the stop claimed" do
      raised = nil
      status = shutdown_status_from { raised = run_to_completion }

      expect(raised).to be_a(Busybee::Worker::Shutdown)
      expect(status.reason).to eq(:signal)
    end
  end

  describe "on a polling worker" do
    let(:worker_class) { corridor_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_poll }

    it_behaves_like "an escalation kept to raise"
  end

  describe "on a streaming worker's buffer consumer" do
    let(:worker_class) { corridor_worker(:streaming) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { deliver_by_stream }

    it_behaves_like "an escalation kept to raise"
  end

  describe "on a hybrid worker draining its backlog" do
    let(:worker_class) { corridor_worker(:hybrid) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      hold_stream_open
      deliver_by_poll
    end

    it_behaves_like "an escalation kept to raise"
  end
end
