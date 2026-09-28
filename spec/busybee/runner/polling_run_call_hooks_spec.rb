# frozen_string_literal: true

require "busybee/testing"

# The call hooks a polling worker's fetch fires, observed through a real client
# over the in-process test transport. The test worker never fetches, so this is
# where the transport-side calls are pinned.
RSpec.describe Busybee::Runner::Polling, "#run!" do
  let(:client) { build_test_client }
  let(:resolved) { [] }
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "polled"
      strict_outputs false

      def perform = { done: true }
    end
  end

  around do |example|
    Busybee::Hooks.isolated do
      Busybee::Hooks.reset!
      Busybee::Hooks.after_call { |call| resolved << call }
      example.run
    end
  end

  # One batch, then stop on the following poll: the job is executed rather than
  # handed back, and run! exits through its ordinary teardown.
  def run_one_batch(key)
    runner = described_class.new(worker_class, runtime_config: Busybee::RuntimeConfig.new(worker_mode: :polling),
                                               client: client)
    batches = [[build_test_raw_job(key: key, type: "polled")]]
    client.on(:activate_jobs) do |_request|
      batch = batches.shift
      next [Busybee::GRPC::ActivateJobsResponse.new(jobs: batch)] if batch

      runner.stop!(reason: :signal)
      []
    end
    runner.run!
  end

  it "fires call hooks for the fetch, the completion, and the idle poll that ends the run" do
    run_one_batch(4100)

    expect(resolved.map(&:rpc)).to eq(%i[activate_jobs complete_job activate_jobs])
  end

  it "correlates the fetches to the worker only, and the completion to the job" do
    run_one_batch(4200)

    fetches = resolved.select { |call| call.rpc == :activate_jobs }
    completion = resolved.find { |call| call.rpc == :complete_job }
    expect(fetches.map(&:job)).to all(be_nil)
    expect(fetches.map(&:worker_status)).to all(have_attributes(worker_class: worker_class, worker_mode: :polling))
    expect(completion.job.key).to eq(4200)
  end
end
