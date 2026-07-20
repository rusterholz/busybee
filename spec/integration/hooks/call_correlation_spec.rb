# frozen_string_literal: true

require "concurrent"

# End-to-end coverage that a Call issued from inside a real job's perform folds
# the curated worker + job correlation, against a live Zeebe cluster. The job's
# autocomplete issues a real complete_job Call through the seam, inside both the
# runner's worker window and the worker's job window, so after_call sees a
# resolved Call carrying both carriers. Unit specs drive the composition with
# doubles; here the whole seed path and the gRPC round-trip are real.
RSpec.describe "Call correlation folding", :integration do
  include Busybee::Testing::Helpers

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new(worker_mode: :polling).resolve_for(worker_class) }
  let(:runner) do
    Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: client)
  end

  # Named (stub_const) so worker_class projects to a name string, not nil.
  let(:worker_class) do
    stub_const("OrderFoldWorker", Class.new(Busybee::Worker) do
      job_type "process-order"
      output :processed
      polling request_timeout: 1_000
      define_method(:perform) { { "processed" => true } }
    end)
  end

  # after_call snapshots the projections (plain hashes) — the Call mutates, but a
  # snapshot of its folded output is stable to retain across threads.
  let(:folded) { Concurrent::Hash.new }

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    Busybee::Hooks.reset!
    Busybee.after_call(rpc: :complete_job) do |call|
      folded[:tags] = call.context_tags
      folded[:log] = call.logging_context
    end
    client.deploy_process(job_bpmn_path)
  end

  after { Busybee::Hooks.reset! }

  it "folds curated worker + job identity into the tags, without lifecycle telemetry" do
    run_one_job

    aggregate_failures do
      expect(folded[:tags]).to include(
        rpc: :complete_job, status: :succeeded, grpc_status: :ok,
        worker_class: "OrderFoldWorker", worker_mode: :polling, job_type: "process-order",
        source: :poll
      )
      expect(folded[:tags]).not_to have_key(:retries)     # engine budget, not this call's attempts
      expect(folded[:tags]).not_to have_key(:worker_name) # per-run-unique → logging only
      expect(folded[:tags]).not_to have_key(:executed_at)
    end
  end

  it "adds worker_name + job/instance keys in logging_context, still no job timings" do
    run_one_job

    aggregate_failures do
      expect(folded[:log]).to include(worker_name: Busybee.worker_name)
      expect(folded[:log][:job_key]).to be_a(Integer)
      expect(folded[:log][:process_instance_key]).to be_a(Integer)
      expect(folded[:log]).not_to have_key(:executed_at)
      expect(folded[:log]).not_to have_key(:deadline)
    end
  end

  private

  def run_one_job(timeout: 15)
    with_process_instance("job-process") do
      runner_thread = Thread.new { runner.run! }
      wait_until(timeout: timeout) { folded.key?(:tags) }
      runner.stop!
      runner_thread.join(5)
    end
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end
end
