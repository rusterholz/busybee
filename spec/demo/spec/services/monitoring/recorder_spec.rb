# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Monitoring::Recorder do
  # Run the background write inline so we can assert on the persisted row within
  # the example's transaction (the real executor writes on another thread/connection).
  before do
    allow(described_class).to receive(:executor).and_return(Concurrent::ImmediateExecutor.new)
  end

  def recorded(job_key) = Monitoring::JobRun.find_by(job_key: job_key)

  describe ".record_activation" do
    it "records buffer depth from the worker status and whether the job was buffered" do
      status = instance_double(Busybee::Worker::Status, current_buffer_size: 4)
      job = build_test_job(key: 4242)
      allow(job).to receive_messages(worker_status: status, buffered?: true)

      described_class.record_activation(job)

      expect(recorded(4242)).to have_attributes(buffer_size: 4, buffered: true)
    end

    it "is nil-safe when no worker status is attached" do
      job = build_test_job(key: 4243)
      allow(job).to receive_messages(worker_status: nil, buffered?: false)

      described_class.record_activation(job)

      expect(recorded(4243)).to have_attributes(buffer_size: nil, buffered: false)
    end
  end
end
