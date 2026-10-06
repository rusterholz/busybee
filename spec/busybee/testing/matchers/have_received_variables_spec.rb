# frozen_string_literal: true

require "busybee/testing/activated_job"
require "busybee/testing/matchers/have_received_variables"

RSpec.describe "have_received_variables matcher" do
  let(:job) do
    Busybee::Testing::ActivatedJob.new(build_test_raw_job(variables: { foo: "bar", count: 42 }), client: nil)
  end

  it "passes when job has expected variables" do
    expect(job).to have_received_variables("foo" => "bar")
  end

  it "passes with symbol keys" do
    expect(job).to have_received_variables(foo: "bar")
  end

  it "takes a Regexp or any matcher as an expected value" do
    expect(job).to have_received_variables(foo: /\Ab/, count: a_value > 40)
  end

  it "fails when a matcher doesn't match" do
    expect do
      expect(job).to have_received_variables(foo: /\Az/)
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError)
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
