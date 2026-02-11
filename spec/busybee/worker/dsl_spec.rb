# frozen_string_literal: true

RSpec.describe Busybee::Worker::DSL do
  let(:minimal_worker) do
    stub_const("MinimalWorker", Class.new(Busybee::Worker))
  end

  describe ".job_type" do
    it "derives default from class name" do
      expect(minimal_worker.job_type).to eq("minimal")
    end

    it "accepts an explicit override" do
      worker = stub_const("CustomTypeWorker", Class.new(Busybee::Worker) do
        job_type "custom-job-type"
      end)
      expect(worker.job_type).to eq("custom-job-type")
    end

    it "converts symbols to strings" do
      worker = stub_const("SymbolTypeWorker", Class.new(Busybee::Worker) do
        job_type :symbol_type
      end)
      expect(worker.job_type).to eq("symbol_type")
    end
  end

  describe ".description" do
    it "defaults to nil" do
      expect(minimal_worker.description).to be_nil
    end

    it "accepts a description string" do
      worker = stub_const("DescribedWorker", Class.new(Busybee::Worker) do
        description "Processes incoming orders"
      end)
      expect(worker.description).to eq("Processes incoming orders")
    end
  end

  describe ".configuration" do
    it "returns a Configuration instance" do
      expect(minimal_worker.configuration).to be_a(Busybee::Worker::Configuration)
    end

    it "is memoized per class" do
      config1 = minimal_worker.configuration
      config2 = minimal_worker.configuration
      expect(config1).to be(config2)
    end

    it "is independent per subclass" do
      other_worker = stub_const("OtherWorker", Class.new(Busybee::Worker))
      expect(minimal_worker.configuration).not_to be(other_worker.configuration)
    end
  end

  # Mission 8: input, variable, header, output, runner_mode, polling, streaming,
  # job_timeout, backoff DSL methods will be tested here.
  # Mission 9: autocomplete, autofail, unhealthy_on DSL methods will be tested here.
end
