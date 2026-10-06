# frozen_string_literal: true

require "busybee/testing/activated_job"
require "busybee/testing/matchers/have_received_headers"

RSpec.describe "have_received_headers matcher" do
  let(:job) do
    Busybee::Testing::ActivatedJob.new(build_test_raw_job(headers: { workflow_version: "v2", batch_id: "42" }),
                                       client: nil)
  end

  it "passes when job has expected headers" do
    expect(job).to have_received_headers("workflow_version" => "v2")
  end

  it "passes with symbol keys" do
    expect(job).to have_received_headers(workflow_version: "v2")
  end

  it "takes a Regexp or any matcher as an expected value" do
    expect(job).to have_received_headers(workflow_version: /\Av/, batch_id: a_string_matching(/\A\d+\z/))
  end

  it "fails when a matcher doesn't match" do
    expect do
      expect(job).to have_received_headers(batch_id: /\Az/)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
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
