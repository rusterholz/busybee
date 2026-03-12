# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Streaming, :integration do
  subject(:runner) { described_class.new(worker_class, runtime_config: runtime_config, client: client) }

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:performed_job_keys) { Concurrent::Array.new }

  let(:worker_class) do
    keys = performed_job_keys
    Class.new(Busybee::Worker) do
      job_type "process-order"

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

  it "processes a job streamed from Zeebe end-to-end" do
    # Start runner BEFORE creating the job — streams only receive jobs
    # created after the stream opens.
    runner_thread = Thread.new { runner.run! }
    sleep 0.5 # allow stream to register with gateway

    with_process_instance("job-process") do
      wait_until(timeout: 10) { performed_job_keys.any? }

      runner.stop!
      runner_thread.join(5)

      expect(performed_job_keys.length).to eq(1)
      expect(runner.running?).to be false

      assert_process_completed!
    end
  end

  it "processes multiple jobs arriving on the stream" do
    instance_keys = []

    begin
      runner_thread = Thread.new { runner.run! }
      sleep 0.5

      3.times { instance_keys << create_job_instance }

      wait_until(timeout: 10) { performed_job_keys.length >= 3 }

      # Create more while stream is still open
      2.times { instance_keys << create_job_instance }

      wait_until(timeout: 10) { performed_job_keys.length >= 5 }

      runner.stop!
      runner_thread.join(5)

      expect(performed_job_keys.length).to eq(5)
      expect(performed_job_keys.uniq.length).to eq(5)
    ensure
      instance_keys.each { |key| cancel_instance(key) }
    end
  end

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

  context "with inline mode (buffer: false)" do
    let(:worker_class) do
      keys = performed_job_keys
      Class.new(Busybee::Worker) do
        job_type "process-order"
        streaming buffer: false

        define_method(:perform) do
          keys << job.key
        end
      end
    end

    it "processes a job streamed from Zeebe end-to-end" do
      runner_thread = Thread.new { runner.run! }
      sleep 0.5

      with_process_instance("job-process") do
        wait_until(timeout: 10) { performed_job_keys.any? }

        runner.stop!
        runner_thread.join(5)

        expect(performed_job_keys.length).to eq(1)
        expect(runner.running?).to be false

        assert_process_completed!
      end
    end

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
