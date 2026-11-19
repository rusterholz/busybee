# frozen_string_literal: true

# Job priority arrived in Camunda 8.10. Each example pins what 8.10 does and
# how an older gateway answers, so every row of the version matrix asserts.
RSpec.describe Busybee::Client, "#update_job_priority" do
  let(:bpmn_path) { File.expand_path("../../fixtures/priority_process.bpmn", __dir__) }

  shared_examples "update_job_priority" do
    around do |example|
      if example.metadata[:skip_process_instance]
        example.run
      else
        client.deploy_process(bpmn_path)

        with_process_instance("priority-process", priority: 42) do
          example.run
        end
      end
    end

    it "reads the priority the BPMN gave the job, or 0 on a gateway that predates priority" do
      seen = nil
      client.with_each_job("prioritized-task", max_jobs: 1) do |job|
        seen = job.priority
        job.complete!
      end

      expect(seen).to eq(gateway_at_least?("8.10") ? 42 : 0)
    end

    it "updates an activated job's priority, which it keeps when activated again" do
      with_activated_job_instance("prioritized-task") do |job|
        unless gateway_at_least?("8.10")
          expect { client.update_job_priority(job.key, 90) }.to raise_error(Busybee::GRPC::Error) do |error|
            expect(error.grpc_status).to eq(:unimplemented)
          end
          next
        end

        expect(client.update_job_priority(job.key, 90)).to be_truthy

        client.fail_job(job.key, "activate it again", retries: 1, backoff: 0)
        expect(activate_job("prioritized-task").priority).to eq(90)
      end
    end

    it "updates the priority through the job itself" do
      client.with_each_job("prioritized-task", max_jobs: 1) do |job|
        if gateway_at_least?("8.10")
          job.update_priority(90)
          expect(job.priority).to eq(90)
        else
          expect { job.update_priority(90) }.to raise_error(Busybee::GRPC::Error)
          expect(job.priority).to eq(0)
        end
        job.complete!
      end
    end

    it "raises error when job key does not exist", :skip_process_instance do
      expected = gateway_at_least?("8.10") ? :not_found : :unimplemented

      expect { client.update_job_priority(999_999_999_999, 5) }.to raise_error(Busybee::GRPC::Error) do |error|
        expect(error.grpc_status).to eq(expected)
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

    it_behaves_like "update_job_priority"
  end

  context "with Camunda Cloud", :camunda_cloud do
    around do |example|
      original = Busybee.credential_type
      Busybee.credential_type = :camunda_cloud
      example.run
      Busybee.credential_type = original
    end

    let(:client) { camunda_cloud_busybee_client }

    it_behaves_like "update_job_priority"
  end
end
