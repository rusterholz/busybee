# frozen_string_literal: true

# A streaming worker's job stream fails, so its stream reader claims the stop
# and announces it there, and on_worker_stop_requested then fails in a way the
# process can't recover from. The run ends on the gateway's error, so that
# hook's error is reported nowhere else.
RSpec.describe "a stop announcement failing unrecoverably after the stream failed", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    stub_const("FailingStreamWorker", Class.new(Busybee::Worker) do
      job_type "failing_stream"
      worker_mode :streaming

      def perform = {}
    end)
  end
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:stream_activated_jobs) { raise GRPC::Internal, "the gateway gave up" }
    Busybee.on_worker_stop_requested { |_status| raise NoMemoryError, "failed to allocate memory" }
  end

  it "logs the hook's error, while the run ends on the gateway's" do
    raised = nil
    lines = capture_busybee_log { raised = run_to_completion }

    expect(raised).to be_a(Busybee::GRPC::Error)
    expect(lines.grep(/\A(WARN|ERROR)/)).
      to eq(["ERROR [busybee] Exiting process immediately: unrecoverable error while " \
             "FailingStreamWorker was stopping (gateway_error) (NoMemoryError: failed to allocate memory)"])
  end
end
