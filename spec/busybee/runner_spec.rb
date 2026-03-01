# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner do
  let(:client) { instance_double(Busybee::Client) }

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"

      def perform
        # no-op
      end
    end
  end

  describe "#initialize" do
    it "accepts an explicit client" do
      runner = described_class.new(client: client)
      expect(runner.instance_variable_get(:@client)).to be(client)
    end

    it "creates a default client when none provided" do
      default_client = instance_double(Busybee::Client)
      allow(Busybee::Client).to receive(:new).and_return(default_client)

      runner = described_class.new
      expect(runner.instance_variable_get(:@client)).to be(default_client)
    end
  end

  describe "#run!" do
    it "raises NotImplementedError" do
      runner = described_class.new(client: client)
      expect { runner.run! }.to raise_error(NotImplementedError)
    end
  end

  describe "#stop!" do
    it "sets stopping? to true" do
      runner = described_class.new(client: client)
      expect(runner.stopping?).to be false

      runner.stop!
      expect(runner.stopping?).to be true
    end
  end

  describe "#stopping?" do
    it "returns false initially" do
      runner = described_class.new(client: client)
      expect(runner.stopping?).to be false
    end
  end

  describe "#running?" do
    it "returns false initially" do
      runner = described_class.new(client: client)
      expect(runner.running?).to be false
    end
  end

  describe "#kill!" do
    it "calls stop!" do
      runner = described_class.new(client: client)
      runner.kill!
      expect(runner.stopping?).to be true
    end
  end

  describe ".for" do
    around do |example|
      original = Busybee.instance_variable_get(:@default_runner_mode)
      example.run
      Busybee.default_runner_mode = original
    end

    context "with a single worker class" do
      it "uses runtime_config to resolve runner type" do
        rc = Busybee::RuntimeConfig.new(runner_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "falls back to worker DSL when no runtime_config" do
        worker_class.runner_mode :polling
        runner = described_class.for(worker_class, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "falls back to gem default when no runtime_config and no worker DSL" do
        Busybee.default_runner_mode = :polling
        runner = described_class.for(worker_class, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "passes the client to the runner" do
        rc = Busybee::RuntimeConfig.new(runner_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        expect(runner.instance_variable_get(:@client)).to be(client)
      end

      it "creates a default client when none provided" do
        default_client = instance_double(Busybee::Client)
        allow(Busybee::Client).to receive(:new).and_return(default_client)

        rc = Busybee::RuntimeConfig.new(runner_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc)
        expect(runner.instance_variable_get(:@client)).to be(default_client)
      end

      it "passes resolved runtime_config to the runner" do
        rc = Busybee::RuntimeConfig.new(runner_mode: :polling, max_jobs: 42)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        resolved_config = runner.instance_variable_get(:@runtime_config)
        expect(resolved_config.max_jobs).to eq(42)
        expect(resolved_config.runner_mode).to eq(:polling)
      end

      it "raises ArgumentError for invalid resolved mode" do
        worker_class.instance_variable_get(:@configuration).instance_variable_set(:@runner_mode, :invalid)
        expect { described_class.for(worker_class, client: client) }.
          to raise_error(ArgumentError, /Invalid runner mode.*:invalid/)
      end
    end

    context "with multiple worker classes" do
      let(:other_worker_class) do
        Class.new(Busybee::Worker) do
          job_type "other_worker"

          def perform
            # no-op
          end
        end
      end

      it "returns a Multi runner" do
        rc = Busybee::RuntimeConfig.new(runner_mode: :polling)
        runner = described_class.for(worker_class, other_worker_class, runtime_config: rc, client: client)
        expect(runner).to be_a(Busybee::Runner::Multi)
      end
    end
  end
end
