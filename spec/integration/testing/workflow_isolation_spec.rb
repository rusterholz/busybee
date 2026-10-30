# frozen_string_literal: true

require "securerandom"

require "busybee/testing/helpers"
require "busybee/testing/no_job_available"
require "busybee/testing/timings"

# What the workflow helpers leave behind, and which jobs they work, against real
# Zeebe. Each example deploys its fixtures under its own process ids and job
# types, so nothing another example leaves running can reach it.
RSpec.describe "Workflow test isolation", :integration do
  let(:suffix) { SecureRandom.hex(4) }
  let(:job_type) { "isolation-#{suffix}" }
  let(:process_id) do
    deploy_fixture("job_process.bpmn", 'type="process-order"' => %(type="#{job_type}"),
                                       "job-process" => "isolation-#{suffix}")
  end

  around do |example|
    saved = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type = saved
  end

  def deploy_fixture(name, replacements)
    bpmn = replacements.reduce(File.read(File.expand_path("../../fixtures/#{name}", __dir__))) do |xml, (from, to)|
      xml.gsub(from, to)
    end
    resource = Busybee::GRPC::Resource.new(name: "#{suffix}-#{name}", content: bpmn)
    grpc_client.deploy_resource(Busybee::GRPC::DeployResourceRequest.new(resources: [resource]))
    replacements.values.last
  end

  def start_instance(id)
    grpc_client.create_process_instance(
      Busybee::GRPC::CreateProcessInstanceRequest.new(bpmnProcessId: id, version: -1)
    ).processInstanceKey
  end

  # Cancels the instance as it asks, so an example cleans up whatever it finds.
  def running?(key)
    grpc_client.cancel_process_instance(Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key))
    true
  rescue GRPC::NotFound
    false
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  it "cancels every instance of nested blocks" do
    keys = []
    with_process_instance(process_id) do |outer|
      keys << outer
      with_process_instance(process_id) { |inner| keys << inner }
    end

    expect(keys.map { |key| running?(key) }).to eq([false, false])
  end

  context "with a leftover instance's job waiting" do
    let!(:leftover) { start_instance(process_id) }

    after { running?(leftover) }

    it "hands the leftover's job back with its retries, and works the example's own" do
      with_process_instance(process_id) do |key|
        expect(activate_job(job_type).process_instance_key).to eq(key)
      end

      back = Busybee::Testing::Helpers.activate_jobs_raw(job_type, max_jobs: 1).first
      expect([back.processInstanceKey, back.retries]).to eq([leftover, 3])
    end
  end

  context "with a call activity" do
    let(:child_type) { "isolation-child-#{suffix}" }
    let(:parent_id) do
      deploy_fixture("call_activity_child.bpmn", 'type="call-activity-child-task"' => %(type="#{child_type}"),
                                                 "call-activity-child" => "isolation-child-#{suffix}")
      deploy_fixture("call_activity_parent.bpmn", "call-activity-child" => "isolation-child-#{suffix}",
                                                  "call-activity-parent" => "isolation-parent-#{suffix}")
    end

    it "refuses the child's job by default, naming it and the switch" do
      with_process_instance(parent_id) do |key|
        expect { activate_job(child_type, timeout: 1_500) }.to raise_error(
          Busybee::Testing::NoJobAvailable,
          /\ANo job of type '#{child_type}' available for process instance #{key}\. Handed back unworked: 1 job of another process instance \(\d+\)\. .* tag it busybee_foreign_jobs: :accept\z/ # rubocop:disable Layout/LineLength
        )
      end
    end

    it "accepts the child's job with busybee_foreign_jobs: :accept", busybee_foreign_jobs: :accept do
      with_process_instance(parent_id) do |key|
        job = activate_job(child_type)
        expect([job.bpmn_process_id, job.process_instance_key == key]).to eq(["isolation-child-#{suffix}", false])
      end
    end
  end

  shared_examples "an enclosing block's job" do
    it "is refused inside the inner block, and the outer block takes it promptly once it resumes" do
      with_process_instance(process_id) do |outer|
        with_process_instance(process_id) do |inner|
          expect(activate_job(job_type).process_instance_key).to eq(inner)
        end

        resumed = now
        expect(activate_job(job_type).process_instance_key).to eq(outer)
        expect(now - resumed).to be < 2.0
      end
    end
  end

  context("when refusing foreign jobs") { it_behaves_like "an enclosing block's job" }

  context("when accepting foreign jobs", busybee_foreign_jobs: :accept) { it_behaves_like "an enclosing block's job" }

  # FOREIGN_JOB_BACKOFF_MS against the engine's own backoff granularity.
  it "re-offers a refused job a few times a second, not in a tight loop" do
    allow(Busybee::Testing::Helpers).to receive(:hand_back).and_call_original
    leftover = start_instance(process_id)

    with_process_instance(process_id) do |key|
      running?(key) # the example's own job never arrives, so only the leftover's is on offer
      expect { activate_job(job_type, timeout: 3_000) }.to raise_error(Busybee::Testing::NoJobAvailable)
    end

    expect(Busybee::Testing::Helpers).to have_received(:hand_back).at_least(2).times
    expect(Busybee::Testing::Helpers).to have_received(:hand_back).
      at_most((3_000 / Busybee::Testing::FOREIGN_JOB_BACKOFF_MS) + 1).times
  ensure
    running?(leftover) if leftover
  end
end
