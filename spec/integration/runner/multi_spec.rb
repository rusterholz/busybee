# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Multi, :integration do
  subject(:runner) { described_class.new([worker_a, worker_b], client: client) }

  let(:multi_job_bpmn_path) { File.expand_path("../../fixtures/multi_job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:performed_a_keys) { Concurrent::Array.new }
  let(:performed_b_keys) { Concurrent::Array.new }

  # Worker A uses polling — fetches jobs via with_each_job loop
  let(:worker_a) do
    keys = performed_a_keys
    Class.new(Busybee::Worker) do
      job_type "job-type-a"
      worker_mode :polling
      polling request_timeout: 1_000

      define_method(:perform) do
        keys << job.key
      end
    end
  end

  # Worker B uses streaming — receives jobs via open_job_stream
  let(:worker_b) do
    keys = performed_b_keys
    Class.new(Busybee::Worker) do
      job_type "job-type-b"
      worker_mode :streaming

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
    client.deploy_process(multi_job_bpmn_path)
  end

  it "creates heterogeneous child runners based on worker DSL" do
    expect(runner.runners[0]).to be_a(Busybee::Runner::Polling)
    expect(runner.runners[1]).to be_a(Busybee::Runner::Streaming)
  end

  it "processes jobs from multiple worker types concurrently" do
    # Start runner before creating instance — streaming worker needs the
    # stream open to receive jobs.
    runner_thread = Thread.new { runner.run! }
    sleep 0.5

    instance_key = create_multi_job_instance

    begin
      wait_until(timeout: 15) { performed_a_keys.any? && performed_b_keys.any? }

      runner.stop!
      runner_thread.join(5)

      expect(performed_a_keys.length).to eq(1)
      expect(performed_b_keys.length).to eq(1)
      expect(runner.running?).to be false
    ensure
      cancel_instance(instance_key)
    end
  end

  it "handles multiple process instances across both worker types" do
    runner_thread = Thread.new { runner.run! }
    sleep 0.5

    instance_keys = []

    begin
      3.times { instance_keys << create_multi_job_instance }

      wait_until(timeout: 15) { performed_a_keys.length >= 3 && performed_b_keys.length >= 3 }

      runner.stop!
      runner_thread.join(5)

      expect(performed_a_keys.length).to eq(3)
      expect(performed_b_keys.length).to eq(3)
      expect(performed_a_keys.uniq.length).to eq(3)
      expect(performed_b_keys.uniq.length).to eq(3)
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
    expect(performed_a_keys).to be_empty
    expect(performed_b_keys).to be_empty
  end

  private

  def create_multi_job_instance
    request = Busybee::GRPC::CreateProcessInstanceRequest.new(
      bpmnProcessId: "multi-job-process",
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
