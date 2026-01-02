# frozen_string_literal: true

require "spec_helper"
require "busybee/defaults"

RSpec.describe Busybee::Defaults do
  it "defines DEFAULT_JOB_TIMEOUT_MS as 60 seconds" do
    expect(described_class::DEFAULT_JOB_TIMEOUT_MS).to eq(60_000)
  end

  it "defines DEFAULT_REQUEST_TIMEOUT_MS as 60 seconds" do
    expect(described_class::DEFAULT_REQUEST_TIMEOUT_MS).to eq(60_000)
  end

  it "defines DEFAULT_MAX_JOBS as 25" do
    expect(described_class::DEFAULT_MAX_JOBS).to eq(25)
  end

  it "defines DEFAULT_MESSAGE_TTL_MS as 10 seconds" do
    expect(described_class::DEFAULT_MESSAGE_TTL_MS).to eq(10_000)
  end

  it "defines DEFAULT_FAIL_JOB_BACKOFF_MS as 5 seconds" do
    expect(described_class::DEFAULT_FAIL_JOB_BACKOFF_MS).to eq(5_000)
  end
end
