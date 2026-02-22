# frozen_string_literal: true

RSpec.describe Busybee::CLI do
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_cli_worker"
      def perform; end
    end
  end

  let(:second_worker_class) do
    Class.new(Busybee::Worker) do
      job_type "second_worker"
      def perform; end
    end
  end

  before { stub_const("TestCLIWorker", worker_class) }

  describe "#initialize" do
    context "with option parsing" do
      it "prints version and exits for --version" do
        expect do
          described_class.new(["--version"])
        end.to output(/#{Regexp.escape(Busybee::VERSION)}/).to_stdout.and raise_error(SystemExit)
      end

      it "prints usage and exits for --help" do
        expect do
          described_class.new(["--help"])
        end.to output(/Usage:/).to_stdout.and raise_error(SystemExit)
      end

      it "parses --runner-mode into runtime config" do
        cli = described_class.new(["--runner-mode", "polling", "TestCLIWorker"])
        expect(cli.runtime_config.runner_mode).to eq(:polling)
      end

      it "defaults runtime config runner_mode to nil when not specified" do
        cli = described_class.new(["TestCLIWorker"])
        expect(cli.runtime_config.runner_mode).to be_nil
      end

      it "accepts the short form -m for runner mode" do
        cli = described_class.new(["-m", "streaming", "TestCLIWorker"])
        expect(cli.runtime_config.runner_mode).to eq(:streaming)
      end

      it "raises on invalid runner mode" do
        expect do
          described_class.new(["--runner-mode", "bogus", "TestCLIWorker"])
        end.to raise_error(ArgumentError, /Invalid runner mode/)
      end

      it "collects remaining positional args as worker class names" do
        cli = described_class.new(["TestCLIWorker"])
        expect(cli.worker_class_names).to eq(["TestCLIWorker"])
      end

      it "collects multiple worker class names" do
        stub_const("SecondCLIWorker", second_worker_class)
        cli = described_class.new(%w[TestCLIWorker SecondCLIWorker])
        expect(cli.worker_class_names).to eq(%w[TestCLIWorker SecondCLIWorker])
      end

      it "raises on unrecognized flags" do
        expect do
          described_class.new(["--bogus-flag", "TestCLIWorker"])
        end.to raise_error(OptionParser::InvalidOption)
      end
    end

    context "with Rails environment loading" do
      it "requires config/environment when Rails is available" do
        loaded_paths = []
        allow_any_instance_of(described_class).to receive(:require) do |_instance, path| # rubocop:disable RSpec/AnyInstance
          loaded_paths << path
          true
        end

        described_class.new(["TestCLIWorker"])
        expect(loaded_paths).to eq(["rails", "./config/environment"])
      end

      it "skips Rails loading when rails gem is not available" do
        loaded_paths = []
        allow_any_instance_of(described_class).to receive(:require) do |_instance, path| # rubocop:disable RSpec/AnyInstance
          loaded_paths << path
          raise LoadError
        end

        described_class.new(["TestCLIWorker"])
        expect(loaded_paths).to eq(["rails"])
      end

      it "skips Rails loading when BUSYBEE_SKIP_RAILS is set" do
        allow_any_instance_of(described_class).to receive(:require) do |_instance, _path| # rubocop:disable RSpec/AnyInstance
          raise "should not be called"
        end

        begin
          ENV["BUSYBEE_SKIP_RAILS"] = "1"
          expect { described_class.new(["TestCLIWorker"]) }.not_to raise_error
        ensure
          ENV.delete("BUSYBEE_SKIP_RAILS")
        end
      end

      it "logs error but does not crash when config/environment fails to load" do
        allow_any_instance_of(described_class).to receive(:require) do |_instance, path| # rubocop:disable RSpec/AnyInstance
          raise StandardError, "boot failed" if path == "./config/environment"
        end

        logger = instance_double(Logger, error: nil, info: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        expect { described_class.new(["TestCLIWorker"]) }.not_to raise_error
        expect(logger).to have_received(:error).with(/\[StandardError\] boot failed.*BUSYBEE_SKIP_RAILS/)
      end
    end

    context "with worker class loading" do
      it "resolves worker class names to constants" do
        cli = described_class.new(["TestCLIWorker"])
        expect(cli.worker_classes).to eq([TestCLIWorker])
      end

      it "resolves multiple worker classes" do
        stub_const("SecondCLIWorker", second_worker_class)
        cli = described_class.new(%w[TestCLIWorker SecondCLIWorker])
        expect(cli.worker_classes).to eq([TestCLIWorker, SecondCLIWorker])
      end

      it "raises when no worker classes are specified" do
        expect do
          described_class.new([])
        end.to raise_error(Busybee::NoWorkersSpecified)
      end

      it "raises when a worker class name cannot be resolved" do
        expect do
          described_class.new(["NonexistentWorker"])
        end.to raise_error(Busybee::WorkerNotFound, /NonexistentWorker/)
      end
    end
  end

  describe "#handle_signal" do
    let(:runner) { instance_double(Busybee::Runner::Polling, stopping?: false, stop!: nil, kill!: nil) }
    let(:cli) { described_class.new(["TestCLIWorker"]) }

    before do
      cli.instance_variable_set(:@runner, runner)
    end

    it "calls stop! on first signal" do
      cli.send(:handle_signal, "TERM")
      expect(runner).to have_received(:stop!)
    end

    it "does not call kill! on first signal" do
      cli.send(:handle_signal, "TERM")
      expect(runner).not_to have_received(:kill!)
    end

    it "calls kill! and exit! on second signal" do
      allow(runner).to receive(:stopping?).and_return(false, true)
      allow(cli).to receive(:exit!)

      cli.send(:handle_signal, "TERM")
      cli.send(:handle_signal, "TERM")

      expect(runner).to have_received(:stop!).once
      expect(runner).to have_received(:kill!).once
      expect(cli).to have_received(:exit!).with(1)
    end
  end

  describe "#run" do
    context "with signal handling setup" do
      let(:cli) { described_class.new(["TestCLIWorker"]) }

      it "traps INT, QUIT, and TERM signals" do
        trapped_signals = []
        allow(cli).to receive(:trap) { |sig, &_block| trapped_signals << sig }

        runner = instance_double(Busybee::Runner::Polling, run!: nil)
        allow(Busybee::Runner).to receive(:for).and_return(runner)

        cli.run
        expect(trapped_signals).to contain_exactly("INT", "QUIT", "TERM")
      end
    end

    context "with runner wiring" do
      let(:runner) { instance_double(Busybee::Runner::Polling, run!: nil) }
      let(:cli) { described_class.new(["TestCLIWorker"]) }

      before do
        allow(cli).to receive(:trap)
        allow(Busybee::Runner).to receive(:for).and_return(runner)
      end

      it "creates a runner via Runner.for with worker classes and runtime config" do
        cli.run
        expect(Busybee::Runner).to have_received(:for).with(
          TestCLIWorker,
          runtime_config: cli.runtime_config,
          client: an_instance_of(Busybee::Client)
        )
      end

      it "calls run! on the runner" do
        cli.run
        expect(runner).to have_received(:run!)
      end

      it "passes multiple worker classes to Runner.for" do
        stub_const("SecondCLIWorker", second_worker_class)
        multi_cli = described_class.new(%w[TestCLIWorker SecondCLIWorker])
        allow(multi_cli).to receive(:trap)

        multi_cli.run

        expect(Busybee::Runner).to have_received(:for).with(
          TestCLIWorker, SecondCLIWorker,
          runtime_config: multi_cli.runtime_config,
          client: an_instance_of(Busybee::Client)
        )
      end

      it "passes runner mode from CLI flags through to RuntimeConfig" do
        mode_cli = described_class.new(["--runner-mode", "polling", "TestCLIWorker"])
        allow(mode_cli).to receive(:trap)
        mode_cli.run

        expect(Busybee::Runner).to have_received(:for).with(
          TestCLIWorker,
          runtime_config: having_attributes(runner_mode: :polling),
          client: an_instance_of(Busybee::Client)
        )
      end
    end
  end
end
