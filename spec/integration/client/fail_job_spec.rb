# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

RSpec.describe Busybee::Client, "#fail_job" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "fail_job" do
    around do |example|
      if example.metadata[:skip_process_instance]
        example.run
      else
        # Deploy the job process
        client.deploy_process(job_bpmn_path)

        with_process_instance("job-process") do
          example.run
        end
      end
    end

    it "fails a job successfully" do
      # Activate the job
      job = activate_job("process-order")

      expect(job.bpmn_process_id).to eq("job-process")
      expect(job.process_instance_key).to eq(process_instance_key)

      # Fail the job
      result = client.fail_job(job.key, "Payment gateway timeout")

      expect(result).to be_truthy
    end

    it "fails a job with custom retry count" do
      # Activate the job
      job = activate_job("process-order")

      # Fail with custom retries
      result = client.fail_job(job.key, "Transient error", retries: 5)

      expect(result).to be_truthy
    end

    it "fails a job with custom backoff as integer" do
      # Activate the job
      job = activate_job("process-order")

      # Fail with custom backoff in milliseconds
      result = client.fail_job(job.key, "Rate limited", backoff: 10_000)

      expect(result).to be_truthy
    end

    it "fails a job with custom backoff as Duration" do
      # Activate the job
      job = activate_job("process-order")

      # Fail with Duration backoff
      result = client.fail_job(job.key, "Temporary failure", backoff: 30.seconds)

      expect(result).to be_truthy
    end

    it "raises error when job key does not exist", :skip_process_instance do
      non_existent_key = 999_999_999_999

      expect { client.fail_job(non_existent_key, "Error") }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
        expect(error.grpc_status).to eq(:not_found)
      end
    end

    it "raises error when trying to fail an already completed job" do
      # Activate a job
      job = activate_job("process-order")

      # Complete the job first
      client.complete_job(job.key)

      # Attempting to fail should raise an error
      expect { client.fail_job(job.key, "Error") }.to raise_error(Busybee::GRPC::Error) do |error|
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

    it_behaves_like "fail_job"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "fail_job"
  end
end
