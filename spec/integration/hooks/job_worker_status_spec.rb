# frozen_string_literal: true

require "concurrent"

# End-to-end coverage that job hooks can see the runner's state through
# job.worker_status against a live Zeebe cluster. The runner stamps a fresh
# Worker::Status into job context at activation and re-stamps it at execution;
# a real job flowing through a real Polling runner therefore carries a real,
# frozen Worker::Status that job hooks read. (The Status is frozen, so the
# captured reference is safe to retain — unlike the Job, which mutates.)
RSpec.describe "job.worker_status visibility", :integration do
  include Busybee::Testing::Helpers

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new(worker_mode: :polling).resolve_for(worker_class) }
  let(:runner) do
    Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: client)
  end

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "process-order"
      output :processed
      polling request_timeout: 1_000
      define_method(:perform) { { "processed" => true } }
    end
  end

  let(:captured) { Concurrent::Hash.new }

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    Busybee::Hooks.reset!
    Busybee.on_job_activated { |job| captured[:activated] = job.worker_status }
    Busybee.on_job_executed  { |job| captured[:executed]  = job.worker_status }
    client.deploy_process(job_bpmn_path)
  end

  after { Busybee::Hooks.reset! }

  it "exposes a Worker::Status to job hooks at activation and execution" do
    run_one_job

    aggregate_failures do
      expect(captured[:activated]).to be_a(Busybee::Worker::Status)
      expect(captured[:executed]).to be_a(Busybee::Worker::Status)
    end
  end

  it "carries the runner's identity and gauges on job.worker_status" do
    run_one_job

    status = captured[:executed]
    aggregate_failures do
      expect(status.worker_class).to eq(worker_class)
      expect(status.worker_mode).to eq(:polling)
      expect(status.job_type).to eq("process-order")
      expect(status.worker_name).to eq(Busybee.worker_name)
      expect(status.started_at).to be_a(Time)
      expect(status.current_buffer_size).to be_nil # polling has no buffer
      expect(status.reason).to be_nil # run still active at execution
    end
  end

  private

  def run_one_job(timeout: 15)
    with_process_instance("job-process") do
      runner_thread = Thread.new { runner.run! }
      wait_until(timeout: timeout) { captured.key?(:executed) }
      runner.stop!
      runner_thread.join(5)
    end
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end
end
