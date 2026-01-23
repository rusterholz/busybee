# frozen_string_literal: true

RSpec.describe Busybee::Client, "#throw_bpmn_error" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "throw_bpmn_error" do
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

    it "throws a BPMN error successfully" do
      # Activate the job
      job = activate_job("process-order")

      expect(job.bpmn_process_id).to eq("job-process")
      expect(job.process_instance_key).to eq(process_instance_key)

      # Throw a BPMN error
      result = client.throw_bpmn_error(job.key, "ORDER_NOT_FOUND")

      expect(result).to be_truthy
    end

    it "throws a BPMN error with message" do
      # Activate the job
      job = activate_job("process-order")

      # Throw error with message
      result = client.throw_bpmn_error(job.key, "PAYMENT_FAILED", message: "Insufficient funds")

      expect(result).to be_truthy
    end

    it "raises error when job key does not exist", :skip_process_instance do
      non_existent_key = 999_999_999_999

      expect { client.throw_bpmn_error(non_existent_key, "ERROR_CODE") }.
        to raise_error(Busybee::GRPC::Error) do |error|
          expect(error.cause).to be_a(GRPC::NotFound)
          expect(error.grpc_status).to eq(:not_found)
        end
    end

    it "raises error when trying to throw error on already completed job" do
      # Activate a job
      job = activate_job("process-order")

      # Complete the job first
      client.complete_job(job.key)

      # Attempting to throw error should fail
      expect { client.throw_bpmn_error(job.key, "ERROR_CODE") }.
        to raise_error(Busybee::GRPC::Error) do |error|
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

    it_behaves_like "throw_bpmn_error"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "throw_bpmn_error"
  end
end
