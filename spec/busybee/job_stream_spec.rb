# frozen_string_literal: true

RSpec.describe Busybee::JobStream do
  let(:client) { instance_double(Busybee::Client) }
  let(:operation) { instance_double(GRPC::ActiveCall::Operation) }
  let(:enumerator) { instance_double(Enumerator) }

  let(:raw_job_one) do
    Busybee::GRPC::ActivatedJob.new(
      key: 111,
      type: "test-job",
      processInstanceKey: 789,
      bpmnProcessId: "test-process",
      variables: '{"foo":"bar"}',
      customHeaders: "{}",
      retries: 3,
      deadline: (Time.now.to_f * 1000).to_i
    )
  end

  let(:raw_job_two) do
    Busybee::GRPC::ActivatedJob.new(
      key: 222,
      type: "test-job",
      processInstanceKey: 790,
      bpmnProcessId: "test-process",
      variables: '{"baz":"qux"}',
      customHeaders: "{}",
      retries: 3,
      deadline: (Time.now.to_f * 1000).to_i
    )
  end

  before do
    allow(operation).to receive(:execute).and_return(enumerator)
  end

  describe "#initialize" do
    it "accepts a gRPC operation and client" do
      stream = described_class.new(operation, client: client)

      expect(stream).to be_a(described_class)
    end

    it "calls execute on the operation to get the enumerator" do
      described_class.new(operation, client: client)

      expect(operation).to have_received(:execute)
    end

    it "starts in non-closed state" do
      stream = described_class.new(operation, client: client)

      expect(stream).not_to be_closed
    end
  end

  describe "#each" do
    it "yields Busybee::Job instances for each raw job in the stream" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one).and_yield(raw_job_two)

      stream = described_class.new(operation, client: client)
      yielded_jobs = stream.map { |job| job }

      expect(yielded_jobs.length).to eq(2)
      expect(yielded_jobs).to all(be_a(Busybee::Job))
    end

    it "wraps raw jobs with correct attributes" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one)

      stream = described_class.new(operation, client: client)
      yielded_job = nil

      stream.each { |job| yielded_job = job }

      expect(yielded_job.key).to eq(111)
      expect(yielded_job.type).to eq("test-job")
    end

    it "wires up the client so job operations delegate correctly" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one)
      allow(client).to receive(:complete_job).and_return(true)

      stream = described_class.new(operation, client: client)
      yielded_job = nil
      stream.each { |job| yielded_job = job }

      yielded_job.complete!

      expect(client).to have_received(:complete_job).with(111, vars: {})
    end

    it "returns an Enumerator when called without a block" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one).and_yield(raw_job_two)

      stream = described_class.new(operation, client: client)

      result = stream.each

      expect(result).to be_a(Enumerator)
      expect(result.map(&:key)).to eq([111, 222])
    end

    it "wraps GRPC errors in Busybee::GRPC::Error" do
      grpc_error = GRPC::Unavailable.new("service unavailable")
      allow(enumerator).to receive(:each).and_raise(grpc_error)

      stream = described_class.new(operation, client: client)

      expect { stream.each { |_job| } }.to raise_error(Busybee::GRPC::Error) # rubocop:disable Lint/EmptyBlock
    end

    it "raises StreamAlreadyClosed when iterating a closed stream" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close

      expect { stream.each { |_job| } }.to raise_error(Busybee::StreamAlreadyClosed) # rubocop:disable Lint/EmptyBlock
    end

    it "raises StreamAlreadyClosed when getting enumerator from closed stream" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close

      expect { stream.each }.to raise_error(Busybee::StreamAlreadyClosed)
    end
  end

  describe "#close" do
    it "cancels the underlying gRPC operation" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close

      expect(operation).to have_received(:cancel)
    end

    it "marks the stream as closed" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close

      expect(stream).to be_closed
    end

    it "is idempotent (calling multiple times does not error)" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close
      stream.close

      expect(operation).to have_received(:cancel).once
    end
  end

  describe "#closed?" do
    it "returns false for a new stream" do
      stream = described_class.new(operation, client: client)

      expect(stream.closed?).to be(false)
    end

    it "returns true after close is called" do
      allow(operation).to receive(:cancel)

      stream = described_class.new(operation, client: client)
      stream.close

      expect(stream.closed?).to be(true)
    end
  end

  describe "Enumerable" do
    it "includes Enumerable module" do
      expect(described_class).to include(Enumerable)
    end

    it "supports Enumerable methods like #map" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one).and_yield(raw_job_two)

      stream = described_class.new(operation, client: client)
      keys = stream.map(&:key)

      expect(keys).to eq([111, 222])
    end

    it "supports Enumerable methods like #first" do
      allow(enumerator).to receive(:each).and_yield(raw_job_one).and_yield(raw_job_two)

      stream = described_class.new(operation, client: client)
      first_job = stream.first

      expect(first_job.key).to eq(111)
    end
  end
end
