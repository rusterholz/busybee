# frozen_string_literal: true

# A buffered streaming runner, with a real client, against a gateway whose job
# stream fails or ends. The pump reads the stream on its own thread, so these are
# the errors that arrive there rather than at a fetch call.
RSpec.describe "a job stream failing under a streaming runner", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "stream_corridor"
      worker_mode :streaming

      def perform; end
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  def streamed(key) = FaultInjectionGateway.activated_job(type: "stream_corridor", key: key, retries: 4)

  context "when the stream reports a status" do
    before { gateway.on(:stream_activated_jobs) { Enumerator.new { |_| raise GRPC::Unavailable, "broker went away" } } }

    it "ends the worker on that status, wrapped, as a gateway event" do
      raised = nil
      status = shutdown_status_from { raised = run_to_completion }

      aggregate_failures do
        expect(raised).to be_a(Busybee::GRPC::Error)
        expect(raised.grpc_status).to eq(:unavailable)
        expect(status.reason).to eq(:gateway_error)
        expect(status.error).to be(raised)
      end
    end
  end

  context "when the stream simply ends" do
    before { gateway.on(:stream_activated_jobs) { [] } }

    it "stops as an engine-side close, not an error" do
      raised = nil
      status = shutdown_status_from { raised = run_to_completion }

      expect(raised).to be_nil
      expect(status).to have_attributes(reason: :gateway_closed, error: nil)
    end
  end

  # Two jobs, then the status. The stream holds the second job until the first
  # is in perform, and that perform holds until the pump's failure has stopped
  # the worker, so the second is still buffered at the drain.
  context "when the stream fails after delivering jobs" do
    let(:performing) { Queue.new }
    let(:worker_class) do
      corridor_runner = -> { runner }
      started = performing
      Class.new(Busybee::Worker) do
        job_type "stream_corridor"
        worker_mode :streaming

        define_method(:perform) do
          started << :performing
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep 0.005 until corridor_runner.call.stopping? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          {}
        end
      end
    end

    before do
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << streamed(1)
          performing.pop
          yielder << streamed(2)
          raise GRPC::Unavailable, "broker went away mid-stream"
        end
      end
    end

    it "finishes the job in flight and hands the buffered one back over the wire" do
      brackets = record_job_brackets
      status = shutdown_status_from { run_to_completion }

      aggregate_failures do
        expect(gateway.received(:complete_job).map(&:jobKey)).to eq([1])
        expect(gateway.received(:fail_job).map { |sent| [sent.jobKey, sent.retries] }).to eq([[2, 4]])
        expect(brackets).to contain_exactly([:activated, 1], [:activated, 2], [:executed, 1], [:not_executed, 2])
        expect(status.reason).to eq(:gateway_error)
      end
    end
  end
end
