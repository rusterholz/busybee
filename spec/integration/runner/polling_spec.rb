# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Polling, :integration do
  subject(:runner) { described_class.new(worker_class, client: client) }

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:performed_job_keys) { Concurrent::Array.new }

  let(:worker_class) do
    keys = performed_job_keys
    Class.new(Busybee::Worker) do
      job_type "process-order"
      polling request_timeout: 1_000 # Short timeout for fast test loops

      define_method(:perform) do
        keys << job.key
      end
    end
  end

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    client.deploy_process(job_bpmn_path)
  end

  it "processes a job from Zeebe end-to-end" do
    with_process_instance("job-process") do
      runner_thread = Thread.new { runner.run! }

      wait_until(timeout: 10) { performed_job_keys.any? }

      runner.stop!
      runner_thread.join(5)

      expect(performed_job_keys.length).to eq(1)
      expect(runner.running?).to be false

      # Worker lifecycle auto-completed the job, so the process should be done
      assert_process_completed!
    end
  end

  it "processes jobs across multiple poll iterations" do
    instance_keys = []

    begin
      # Create initial batch — all picked up in a single with_each_job call
      3.times { instance_keys << create_job_instance }

      runner_thread = Thread.new { runner.run! }

      wait_until(timeout: 10) { performed_job_keys.length >= 3 }

      # Create more instances — requires a subsequent poll iteration
      2.times { instance_keys << create_job_instance }

      wait_until(timeout: 10) { performed_job_keys.length >= 5 }

      runner.stop!
      runner_thread.join(5)

      expect(performed_job_keys.length).to eq(5)
      expect(performed_job_keys.uniq.length).to eq(5) # All unique job keys
    ensure
      instance_keys.each { |key| cancel_instance(key) }
    end
  end

  it "exits cleanly when stopped with no pending jobs" do
    # No process instances created — no jobs available
    runner_thread = Thread.new { runner.run! }

    # Give the runner time to enter the poll loop
    sleep 0.5
    expect(runner.running?).to be true

    runner.stop!
    runner_thread.join(5)

    expect(runner.running?).to be false
    expect(runner.stopping?).to be true
    expect(performed_job_keys).to be_empty
  end

  private

  def create_job_instance
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: "job-process",
      version: -1,
      variables: "{}"
    )
    response = grpc_client.create_process_instance(request)
    response.processInstanceKey
  end

  def cancel_instance(key)
    request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key)
    grpc_client.cancel_process_instance(request)
  rescue GRPC::NotFound
    # Already completed
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end
end
