# frozen_string_literal: true

RSpec.describe Busybee::RuntimeConfig do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"
      def perform; end
    end
  end

  before { stub_const("TestWorker", worker_class) }

  around do |example|
    original = Busybee.instance_variable_get(:@default_runner_mode)
    example.run
    Busybee.default_runner_mode = original
  end

  describe "#initialize" do
    it "accepts runner_mode" do
      config = described_class.new(runner_mode: :polling)
      expect(config.runner_mode).to eq(:polling)
    end

    it "defaults runner_mode to nil" do
      config = described_class.new
      expect(config.runner_mode).to be_nil
    end

    it "accepts per-worker overrides" do
      config = described_class.new(
        runner_mode: :hybrid,
        workers: { "TestWorker" => { runner_mode: :polling } }
      )
      expect(config.runner_mode).to eq(:hybrid)
    end

    it "validates runner_mode" do
      expect { described_class.new(runner_mode: :invalid) }.
        to raise_error(ArgumentError, /Invalid runner mode.*:invalid/)
    end

    it "validates per-worker runner_mode" do
      expect { described_class.new(workers: { "TestWorker" => { runner_mode: :bogus } }) }.
        to raise_error(ArgumentError, /Invalid runner mode.*:bogus/)
    end
  end

  describe "#resolve_for" do
    context "with multiple config sources" do
      it "uses per-worker override over global override" do
        config = described_class.new(
          runner_mode: :hybrid,
          workers: { "TestWorker" => { runner_mode: :polling } }
        )
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:polling)
      end

      it "uses global override when no per-worker override" do
        config = described_class.new(runner_mode: :hybrid)
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:hybrid)
      end

      it "falls back to worker DSL when no RuntimeConfig override" do
        worker_class.runner_mode :streaming
        config = described_class.new
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:streaming)
      end

      it "falls back to gem default when no other source" do
        Busybee.default_runner_mode = :polling
        config = described_class.new
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:polling)
      end

      it "prefers per-worker RuntimeConfig over worker DSL" do
        worker_class.runner_mode :streaming
        config = described_class.new(
          workers: { "TestWorker" => { runner_mode: :polling } }
        )
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:polling)
      end

      it "prefers global RuntimeConfig over worker DSL" do
        worker_class.runner_mode :streaming
        config = described_class.new(runner_mode: :hybrid)
        resolved = config.resolve_for(worker_class)
        expect(resolved.runner_mode).to eq(:hybrid)
      end
    end

    it "returns a RuntimeConfig" do
      config = described_class.new(runner_mode: :polling)
      resolved = config.resolve_for(worker_class)
      expect(resolved).to be_a(described_class)
    end

    it "handles worker with no per-worker override" do
      other_worker = Class.new(Busybee::Worker) do
        job_type "other"
        def perform; end
      end
      stub_const("OtherWorker", other_worker)

      config = described_class.new(
        runner_mode: :hybrid,
        workers: { "TestWorker" => { runner_mode: :polling } }
      )
      resolved = config.resolve_for(other_worker)
      expect(resolved.runner_mode).to eq(:hybrid)
    end
  end
end
