# frozen_string_literal: true

# A stop arriving with a job in hand, on each receive path, with a real client:
# what the engine is sent for the job handed back, and what hooks see of it. The
# stop comes from the second job's activation hook, which puts it in hand exactly
# when the worker learns it is stopping.
RSpec.describe "handing a job back on shutdown", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:handed_back) { Concurrent::Array.new }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    Busybee::Hooks.on_job_activated { |job| runner.stop!(reason: :sigterm) if job.key == 2 }
    Busybee::Hooks.on_job_not_executed { |job| handed_back << job }
  end

  def corridor_worker(mode, **streaming)
    Class.new(Busybee::Worker) do
      job_type "handback_corridor"
      worker_mode mode
      fail_job_backoff 1234
      streaming(**streaming) if streaming.any?

      def perform; end
    end
  end

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "handback_corridor", key: key, retries: 4)

  def fail_jobs_sent = gateway.received(:fail_job).map { |sent| [sent.jobKey, sent.retries, sent.retryBackOff] }

  shared_examples "a handback with the job in hand" do
    it "works the first job and sends the second back unworked, retries and backoff intact" do
      run_to_completion

      expect(gateway.received(:complete_job).map(&:jobKey)).to eq([1])
      expect(fail_jobs_sent).to eq([[2, 4, 1234]])
    end

    it "leaves the handed-back job :ready, with nothing on its error axis" do
      run_to_completion

      expect(handed_back.map { |job| [job.key, job.status, job.error] }).to eq([[2, :ready, nil]])
    end

    it "closes every activation exactly once" do
      brackets = record_job_brackets
      run_to_completion

      expect(brackets).to eq([[:activated, 1], [:executed, 1], [:activated, 2], [:not_executed, 2]])
    end
  end

  describe "a polling worker" do
    let(:worker_class) { corridor_worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1), wire_job(2)])] }
    end

    it_behaves_like "a handback with the job in hand"

    context "when the engine can't be reached to take the job back" do
      before { gateway.on(:fail_job) { raise GRPC::Unavailable, "broker gone" } }

      it "still closes the activation, and puts the failure on the worker rather than the job" do
        run_to_completion

        job = handed_back.first
        aggregate_failures do
          expect(handed_back.map(&:key)).to eq([2])
          expect(job.error).to be_nil
          expect(job.worker_status.error).to be_a(Busybee::GRPC::Error)
          expect(job.worker_status.error.grpc_status).to eq(:unavailable)
        end
      end
    end
  end

  # The stream stays open until the example ends; closing the gate releases the
  # gateway's handler thread before the gateway is stopped.
  describe "a streaming worker reading inline" do
    let(:worker_class) { corridor_worker(:streaming, buffer: false) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
    let(:stream_gate) { Queue.new }

    before do
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          yielder << wire_job(2)
          stream_gate.pop
        end
      end
    end

    after { stream_gate.close }

    it_behaves_like "a handback with the job in hand"
  end

  describe "a hybrid worker draining its backlog" do
    let(:worker_class) { corridor_worker(:hybrid) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
    let(:stream_gate) { Queue.new }

    before do
      gateway.on(:stream_activated_jobs) { Enumerator.new { |_| stream_gate.pop } }
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1), wire_job(2)])] }
    end

    after { stream_gate.close }

    it_behaves_like "a handback with the job in hand"
  end
end
