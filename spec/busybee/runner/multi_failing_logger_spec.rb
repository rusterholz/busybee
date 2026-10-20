# frozen_string_literal: true

# A multi-worker process whose logger raises on every write, while one worker
# dies of a gateway error: its stream fails, and its sibling is idle, polling
# an empty queue.
RSpec.describe "a multi-worker process whose logger fails", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:failing_logger) do
    Class.new do
      %i[debug info warn error].each do |level|
        define_method(level) { |_message| raise IOError, "closed stream" }
      end
    end.new
  end

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

  around do |example|
    saved = Busybee.logger
    Busybee.logger = failing_logger
    isolate_busybee_hooks { example.run }
  ensure
    Busybee.logger = saved
  end

  before do
    gateway.on(:stream_activated_jobs) { raise GRPC::Internal, "broker lost the stream" }
    gateway.on(:activate_jobs) do
      sleep 0.05
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
    end
  end

  it "still stops the sibling when logging the worker's failure fails" do
    raised = nil
    expect { raised = run_to_completion(seconds: 3) }.to output(/failed to log/).to_stderr

    expect(raised).to be_a(Busybee::GRPC::Error)
  end
end
