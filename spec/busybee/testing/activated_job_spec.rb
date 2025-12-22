# frozen_string_literal: true

require "busybee/testing/activated_job"
require "json"

RSpec.describe Busybee::Testing::ActivatedJob do
  subject(:job) { described_class.new(raw_job, client: client) }

  let(:raw_job) do
    # Using plain double since protobuf generates accessors dynamically.
    # Field names verified against proto/gateway.proto ActivatedJob message.
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 12_345,
      processInstanceKey: 67_890,
      variables: '{"foo": "bar", "count": 42}',
      customHeaders: '{"task_type": "process_order"}',
      retries: 3
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end
  let(:client) { instance_double(Busybee::GRPC::Gateway::Stub) }

  describe "#key" do
    it "returns the job key" do
      expect(job.key).to eq(12_345)
    end
  end

  describe "#process_instance_key" do
    it "returns the process instance key" do
      expect(job.process_instance_key).to eq(67_890)
    end
  end

  describe "#variables" do
    it "parses and returns variables as a hash with string keys" do
      expect(job.variables).to eq("foo" => "bar", "count" => 42)
    end

    it "memoizes the result" do
      expect(JSON).to receive(:parse).once.and_call_original # rubocop:disable RSpec/MessageSpies
      job.variables
      job.variables # second call should not parse again
    end
  end

  describe "#headers" do
    it "parses and returns custom headers as a hash with string keys" do
      expect(job.headers).to eq("task_type" => "process_order")
    end

    it "memoizes the result" do
      expect(JSON).to receive(:parse).once.and_call_original # rubocop:disable RSpec/MessageSpies
      job.headers
      job.headers # second call should not parse again
    end
  end

  describe "#retries" do
    it "returns the retry count" do
      expect(job.retries).to eq(3)
    end
  end
end
