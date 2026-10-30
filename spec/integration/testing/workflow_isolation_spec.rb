# frozen_string_literal: true

require "securerandom"

require "busybee/testing/helpers"

# What the workflow helpers leave behind, and what they work, against real Zeebe.
# Each example deploys job_process.bpmn under its own process id and job type,
# so nothing another example leaves running can reach it.
RSpec.describe "Workflow test isolation", :integration do
  let(:job_type) { "isolation-#{SecureRandom.hex(4)}" }
  let(:process_id) { deploy_job_process(job_type) }

  around do |example|
    saved = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
  ensure
    Busybee.credential_type = saved
  end

  def deploy_job_process(type)
    id = "isolation-#{SecureRandom.hex(4)}"
    bpmn = File.read(File.expand_path("../../fixtures/job_process.bpmn", __dir__)).
           gsub('type="process-order"', %(type="#{type}")).gsub("job-process", id)
    resource = Busybee::GRPC::Resource.new(name: "#{id}.bpmn", content: bpmn)
    grpc_client.deploy_resource(Busybee::GRPC::DeployResourceRequest.new(resources: [resource]))
    id
  end

  # Cancels the instance as it asks, so an example cleans up whatever it finds.
  def running?(key)
    grpc_client.cancel_process_instance(Busybee::GRPC::CancelProcessInstanceRequest.new(processInstanceKey: key))
    true
  rescue GRPC::NotFound
    false
  end

  it "cancels every instance of nested blocks" do
    keys = []
    with_process_instance(process_id) do |outer|
      keys << outer
      with_process_instance(process_id) { |inner| keys << inner }
    end

    expect(keys.map { |key| running?(key) }).to eq([false, false])
  end
end
