# frozen_string_literal: true

RSpec.describe Busybee::Client, "#update_job_timeout" do
  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }

  shared_examples "update_job_timeout" do
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

    it "updates job timeout successfully" do
      with_activated_job_instance("process-order") do |job|
        result = client.update_job_timeout(job.key, 30_000)

        expect(result).to be_truthy
      end
    end

    it "supports Duration objects" do
      with_activated_job_instance("process-order") do |job|
        result = client.update_job_timeout(job.key, 30.seconds)

        expect(result).to be_truthy
      end
    end

    it "raises error when job key does not exist", :skip_process_instance do
      non_existent_key = 999_999_999_999

      expect { client.update_job_timeout(non_existent_key, 30_000) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.cause).to be_a(GRPC::NotFound)
        expect(error.grpc_status).to eq(:not_found)
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

    it_behaves_like "update_job_timeout"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "update_job_timeout"
  end
end
