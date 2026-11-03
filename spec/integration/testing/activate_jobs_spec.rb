# frozen_string_literal: true

require "securerandom"

require "busybee/testing/helpers"

# activate_jobs against real Zeebe. Each example deploys its own process id and
# job type, so nothing another example leaves running can reach it.
RSpec.describe "activate_jobs", :integration do
  let(:suffix) { SecureRandom.hex(4) }
  let(:job_type) { "activate-jobs-#{suffix}" }
  let(:process_id) do
    bpmn = File.read(File.expand_path("../../fixtures/job_process.bpmn", __dir__)).
           gsub('type="process-order"', %(type="#{job_type}")).
           gsub("job-process", "activate-jobs-#{suffix}")
    resource = Busybee::GRPC::Resource.new(name: "#{suffix}.bpmn", content: bpmn)
    grpc_client.deploy_resource(Busybee::GRPC::DeployResourceRequest.new(resources: [resource]))
    "activate-jobs-#{suffix}"
  end

  around do |example|
    saved = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type = saved
  end

  it "returns the same jobs on a second read, without activating again" do
    with_process_instance(process_id) do
      jobs = activate_jobs(job_type, max_jobs: 5, timeout: 500)

      first_read = jobs.map(&:key)
      second_read = jobs.map(&:key)

      expect(first_read.size).to eq(1)
      expect(second_read).to eq(first_read)
    end
  end
end
