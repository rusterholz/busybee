# frozen_string_literal: true

RSpec.describe Busybee::Client, "#complete_job" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "complete_job" do
    before do
      # Deploy the job process
      client.deploy_process(job_bpmn_path)
    end

    it "completes a job successfully" do
      # Start a process instance that will create a job
      instance_key = client.start_instance("job-process")

      # Activate the job
      job = activate_job("process-order")

      expect(job.bpmn_process_id).to eq("job-process")
      expect(job.process_instance_key).to eq(instance_key)

      # Complete the job
      result = client.complete_job(job.key)

      expect(result).to be_truthy
    end

    it "completes a job with output variables" do
      # Start a process instance
      client.start_instance("job-process")

      # Activate the job
      job = activate_job("process-order")

      # Complete with variables
      result = client.complete_job(job.key, vars: { result: "success", orderId: 123 })

      expect(result).to be_truthy
    end

    it "raises error when job key does not exist" do
      non_existent_key = 999_999_999_999

      expect { client.complete_job(non_existent_key) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
        expect(error.grpc_status).to eq(:not_found)
      end
    end

    it "raises error when trying to complete an already completed job" do
      # Start and activate a job
      client.start_instance("job-process")
      job = activate_job("process-order")

      # Complete the job once
      client.complete_job(job.key)

      # Attempting to complete again should raise an error
      expect { client.complete_job(job.key) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
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

    it_behaves_like "complete_job"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "complete_job"
  end
end
