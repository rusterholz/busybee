# frozen_string_literal: true

require "busybee/testing/matchers/have_received_variables"
require "busybee/testing/activated_job"

RSpec.describe "have_received_variables matcher" do
  # Using plain double since protobuf generates accessors dynamically
  # rubocop:disable RSpec/VerifiedDoubles
  let(:raw_job) do
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 1,
      processInstanceKey: 2,
      variables: '{"foo": "bar", "count": 42}',
      customHeaders: "{}",
      retries: 3
    )
  end
  let(:client) { instance_double(Busybee::GRPC::Gateway::Stub) }
  # rubocop:enable RSpec/VerifiedDoubles
  let(:job) { Busybee::Testing::ActivatedJob.new(raw_job, client: client) }

  it "passes when job has expected variables" do
    expect(job).to have_received_variables("foo" => "bar")
  end

  it "passes with symbol keys" do
    expect(job).to have_received_variables(foo: "bar")
  end

  it "fails when job lacks expected variables" do
    expect do
      expect(job).to have_received_variables("missing" => "value")
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
  end

  it "provides helpful failure message" do
    expect do
      expect(job).to have_received_variables("wrong" => "value")
    end.to raise_error(/expected job variables to include/)
  end
end
