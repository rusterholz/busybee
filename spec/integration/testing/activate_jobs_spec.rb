# frozen_string_literal: true

require "securerandom"

require "busybee/testing/helpers"
require "busybee/testing/no_jobs_available"

# activate_jobs against real Zeebe. Each example deploys its own process id and
# job type, so nothing another example leaves running can reach it. An instance
# of the fixture has one job of the type at once, and a second on its message.
RSpec.describe "activate_jobs", :integration do
  let(:suffix) { SecureRandom.hex(4) }
  let(:job_type) { "staggered-#{suffix}" }
  let(:process_id) do
    bpmn = File.read(File.expand_path("../../fixtures/staggered_jobs_process.bpmn", __dir__)).
           gsub("staggered-task", job_type).
           gsub("staggered-jobs-process", "staggered-#{suffix}")
    resource = Busybee::GRPC::Resource.new(name: "#{suffix}.bpmn", content: bpmn)
    grpc_client.deploy_resource(Busybee::GRPC::DeployResourceRequest.new(resources: [resource]))
    "staggered-#{suffix}"
  end
  let(:correlation_id) { "own-#{suffix}" }

  around do |example|
    saved = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type = saved
  end

  def release_second_job(id = correlation_id) = publish_message("staggered-continue", correlation_key: id)
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  context "with a job created only after the activation began" do
    it "waits for it under expected:" do
      with_process_instance(process_id, correlationId: correlation_id) do |key|
        started = now
        publisher = Thread.new do
          sleep 0.5
          release_second_job
        end
        jobs = activate_jobs(job_type, expected: 2)

        expect(now - started).to be >= 0.5
        expect(jobs.map(&:key).uniq.size).to eq(2)
        expect(jobs.map(&:process_instance_key)).to eq([key, key])
      ensure
        publisher&.join
      end
    end

    it "doesn't wait for it under max_jobs:" do
      with_process_instance(process_id, correlationId: correlation_id) do
        expect(activate_jobs(job_type, max_jobs: 2).size).to eq(1)
      end
    end
  end

  it "raises at the end of the wait when too few arrive, naming what it got" do
    with_process_instance(process_id, correlationId: correlation_id) do |key|
      started = now

      expect { activate_jobs(job_type, expected: 2, timeout: 500) }.to raise_error(
        Busybee::Testing::NoJobsAvailable,
        "Expected 2 jobs of type '#{job_type}' for process instance #{key}, got 1"
      )
      expect(now - started).to be >= 0.5
    end
  end

  it "leaves any jobs past the expected number in the engine" do
    with_process_instance(process_id, correlationId: correlation_id) do
      release_second_job

      taken = activate_jobs(job_type, expected: 1)

      expect(taken.size).to eq(1)
      expect(activate_job(job_type, timeout: 1_000).key).not_to eq(taken.first.key)
    end
  end

  context "with a leftover instance's jobs waiting" do
    let(:leftover) do
      grpc_client.create_process_instance(
        Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: process_id, version: -1,
          variables: Busybee::Serialization.to_json(correlationId: "leftover-#{suffix}")
        )
      ).processInstanceKey
    end

    before do
      leftover
      release_second_job("leftover-#{suffix}")
    end

    after do
      grpc_client.cancel_process_instance(Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: leftover))
    end

    it "hands them back, and returns only its own" do
      allow(Busybee::Testing::Helpers).to receive(:hand_back).and_call_original

      with_process_instance(process_id, correlationId: correlation_id) do |key|
        release_second_job

        expect(activate_jobs(job_type, expected: 2).map(&:process_instance_key)).to eq([key, key])
      end

      expect(Busybee::Testing::Helpers).to have_received(:hand_back).at_least(:once)
      back = activate_jobs(job_type, expected: 2)
      expect(back.map { |job| [job.process_instance_key, job.retries] }).to eq([[leftover, 3], [leftover, 3]])
    end
  end

  [{ expected: 1 }, { max_jobs: 5 }].each do |count|
    it "returns the same jobs on a second read, without activating again, under #{count.keys.first}:" do
      with_process_instance(process_id, correlationId: correlation_id) do
        jobs = activate_jobs(job_type, **count, timeout: 500)

        first_read = jobs.map(&:key)
        second_read = jobs.map(&:key)

        expect(first_read.size).to eq(1)
        expect(second_read).to eq(first_read)
      end
    end
  end
end
