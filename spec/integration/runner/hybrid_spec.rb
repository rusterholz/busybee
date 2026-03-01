# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Hybrid, :integration do
  subject(:runner) { described_class.new(worker_class, runtime_config: runtime_config, client: client) }

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:performed_job_keys) { Concurrent::Array.new }

  # max_jobs: 3 forces multiple poll cycles during drain — 10 jobs = 4 polls (3+3+3+1).
  let(:worker_class) do
    keys = performed_job_keys
    Class.new(Busybee::Worker) do
      job_type "process-order"
      polling max_jobs: 3

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

  context "with heavy backlog and no stream work" do
    it "drains all pre-existing jobs across multiple poll cycles" do
      # 10 jobs with max_jobs: 3 → 4 poll cycles (3+3+3+1), plus caught-up detection (1 < 3)
      instance_keys = 10.times.map { create_job_instance }

      begin
        runner_thread = Thread.new { runner.run! }

        wait_until(timeout: 15) { performed_job_keys.length >= 10 }

        runner.stop!
        runner_thread.join(5)

        expect(performed_job_keys.length).to eq(10)
        expect(performed_job_keys.uniq.length).to eq(10)
        expect(runner.running?).to be false
      ensure
        instance_keys.each { |key| cancel_instance(key) }
      end
    end
  end

  context "with heavy stream work and no backlog" do
    it "processes all jobs arriving via stream after empty drain" do
      runner_thread = Thread.new { runner.run! }
      sleep 0.5 # allow stream to register and drain to complete (no backlog → immediate)

      instance_keys = []
      begin
        8.times { instance_keys << create_job_instance }

        wait_until(timeout: 15) { performed_job_keys.length >= 8 }

        runner.stop!
        runner_thread.join(5)

        expect(performed_job_keys.length).to eq(8)
        expect(performed_job_keys.uniq.length).to eq(8)
      ensure
        instance_keys.each { |key| cancel_instance(key) }
      end
    end
  end

  context "with heavy backlog and stream work" do
    it "drains backlog via polling then transitions to processing stream jobs" do
      # 7 backlog jobs = 3 poll cycles (3+3+1)
      instance_keys = 7.times.map { create_job_instance }

      begin
        runner_thread = Thread.new { runner.run! }

        # Wait for backlog to drain
        wait_until(timeout: 15) { performed_job_keys.length >= 7 }

        # Now create more jobs — these can only arrive via stream (backlog is drained,
        # and the gateway routes new jobs to the open stream, not to polls)
        5.times { instance_keys << create_job_instance }

        wait_until(timeout: 15) { performed_job_keys.length >= 12 }

        runner.stop!
        runner_thread.join(5)

        expect(performed_job_keys.length).to eq(12)
        expect(performed_job_keys.uniq.length).to eq(12)
      ensure
        instance_keys.each { |key| cancel_instance(key) }
      end
    end
  end

  context "with no work" do
    it "exits cleanly when stopped with no pending jobs" do
      runner_thread = Thread.new { runner.run! }

      sleep 0.5
      expect(runner.running?).to be true

      runner.stop!
      runner_thread.join(5)

      expect(runner.running?).to be false
      expect(runner.stopping?).to be true
      expect(performed_job_keys).to be_empty
    end
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
