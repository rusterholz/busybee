# frozen_string_literal: true

RSpec.describe Busybee::Client, "#with_each_job" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "with_each_job" do
    around do |example|
      # Deploy the job process
      client.deploy_process(job_bpmn_path)

      if example.metadata[:skip_process_instance]
        example.run
      else
        with_process_instance("job-process") do
          example.run
        end
      end
    end

    it "activates and yields jobs to the block" do
      yielded_jobs = []

      count = client.with_each_job("process-order", max_jobs: 5) do |job|
        yielded_jobs << job
        job.complete!
      end

      expect(count).to eq(1)
      expect(yielded_jobs.length).to eq(1)
      expect(yielded_jobs.first).to be_a(Busybee::Job)
      expect(yielded_jobs.first.type).to eq("process-order")
    end

    it "returns count of jobs processed" do
      count = client.with_each_job("process-order", &:complete!)

      expect(count).to eq(1)
    end

    it "supports custom job_timeout" do
      count = client.with_each_job("process-order", job_timeout: 10.seconds, request_timeout: 1.second, &:complete!)

      expect(count).to eq(1)
    end

    it "supports custom request_timeout" do
      count = client.with_each_job("process-order", request_timeout: 1.second, &:complete!)

      expect(count).to eq(1)
    end

    it "returns zero when no jobs available" do
      count = client.with_each_job("non-existent-job-type", request_timeout: 100) do |_job|
        # This block should not execute
        raise "Should not reach here"
      end

      expect(count).to eq(0)
    end

    it "processes jobs from multiple process instances", :skip_process_instance do # rubocop:disable RSpec/ExampleLength
      # Create multiple process instances
      instance_keys = []
      3.times do
        request = Busybee::GRPC::CreateProcessInstanceRequest.new(
          bpmnProcessId: "job-process",
          version: -1,
          variables: "{}"
        )
        response = grpc_client.create_process_instance(request)
        instance_keys << response.processInstanceKey
      end

      begin
        # Activate and process all jobs
        processed_jobs = []
        count = client.with_each_job("process-order", max_jobs: 10) do |job|
          processed_jobs << job.key
          job.complete!
        end

        expect(count).to eq(3)
        expect(processed_jobs.length).to eq(3)
        expect(processed_jobs.uniq.length).to eq(3) # All unique job keys
      ensure
        # Clean up all instances
        instance_keys.each do |key|
          request = Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key)
          grpc_client.cancel_process_instance(request)
        rescue GRPC::NotFound
          # Already completed, ignore
        end
      end
    end
  end

  context "with local Zeebe", :integration do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :insecure
      example.run
      Busybee.credential_type = original
    end

    let(:client) { local_busybee_client }

    it_behaves_like "with_each_job"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "with_each_job"
  end
end
