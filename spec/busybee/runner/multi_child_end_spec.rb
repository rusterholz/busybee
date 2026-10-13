# frozen_string_literal: true

require "concurrent"

# One worker of a multi-worker process stops on its own while the process
# isn't stopping, with a real client: its stream closes cleanly, and its
# sibling is idle, polling an empty queue.
RSpec.describe "a multi-worker process whose worker stops on its own", :gateway do # rubocop:disable RSpec/DescribeClass
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

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:stream_activated_jobs) { [FaultInjectionGateway.activated_job(type: "alpha", key: 1)] }
    gateway.on(:activate_jobs) do
      sleep 0.05
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
    end
  end

  it "stops the rest gracefully, under that worker's reason, rather than leaving its job type unworked" do
    statuses = shutdown_statuses_from { expect(run_to_completion(seconds: 3)).to be_nil }

    reasons = statuses.map { |status| [status.worker_class, status.reason] }
    expect(reasons).to contain_exactly([alpha_class, :gateway_closed], [beta_class, :gateway_closed])
  end
end
