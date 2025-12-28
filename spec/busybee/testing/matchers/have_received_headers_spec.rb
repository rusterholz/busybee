# frozen_string_literal: true

require "busybee/testing/matchers/have_received_headers"
require "busybee/testing/activated_job"

RSpec.describe "have_received_headers matcher" do
  # Using plain double since protobuf generates accessors dynamically
  # rubocop:disable RSpec/VerifiedDoubles
  let(:raw_job) do
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 1,
      processInstanceKey: 2,
      variables: "{}",
      customHeaders: '{"workflow_version": "v2", "batch_id": "42"}',
      retries: 3
    )
  end
  let(:client) { instance_double(Busybee::GRPC::Gateway::Stub) }
  # rubocop:enable RSpec/VerifiedDoubles
  let(:job) { Busybee::Testing::ActivatedJob.new(raw_job, client: client) }

  it "passes when job has expected headers" do
    expect(job).to have_received_headers("workflow_version" => "v2")
  end

  it "passes with symbol keys" do
    expect(job).to have_received_headers(workflow_version: "v2")
  end

  it "fails when job lacks expected headers" do
    expect do
      expect(job).to have_received_headers("missing" => "value")
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end

  it "provides helpful failure message" do
    expect do
      expect(job).to have_received_headers("wrong" => "value")
    end.to raise_error(/expected job headers to include/)
  end
end
