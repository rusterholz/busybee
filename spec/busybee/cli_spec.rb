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

  # Save/restore gem-level config that apply_global_config! may modify
  around do |example|
    saved = %i[@log_format @worker_name @cluster_address].to_h do |ivar|
      [ivar, Busybee.instance_variable_get(ivar)]
    end
    example.run
  ensure
    saved.each { |ivar, val| Busybee.instance_variable_set(ivar, val) }
  end

  describe "#initialize" do
    context "with option parsing" do
      it "prints version and exits for --version" do
        expect do
          described_class.new(["--version"])
        end.to output(/#{Regexp.escape(Busybee::VERSION)}/).to_stdout.and raise_error(SystemExit)
      end

      it "prints version and exits for -v" do
        expect do
          described_class.new(["-v"])
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

      it "parses --log-format and its short form -l" do
        cli = described_class.new(["-l", "json", "TestCLIWorker"])
        expect(cli.runtime_config.log_format).to eq(:json)
      end

      it "parses --worker-name and its short form -n" do
        cli = described_class.new(["-n", "my-worker", "TestCLIWorker"])
        expect(cli.runtime_config.worker_name).to eq("my-worker")
      end

      it "parses --cluster-address and its short form -a" do
        cli = described_class.new(["-a", "zeebe.example.com:26500", "TestCLIWorker"])
        expect(cli.runtime_config.cluster_address).to eq("zeebe.example.com:26500")
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

    context "with --config flag" do
      let(:yaml_dir) { File.join(__dir__, "..", "..", "tmp", "yaml_fixtures") }

      before { FileUtils.mkdir_p(yaml_dir) }

      after { FileUtils.rm_rf(yaml_dir) }

      def write_yaml(filename, content)
        path = File.join(yaml_dir, filename)
        File.write(path, content)
        path
      end

      it "stores config_file path from -c" do
        cli = described_class.allocate
        cli.send(:instance_variable_set, :@worker_class_names, [])
        cli.send(:instance_variable_set, :@parsed_options, {})
        cli.send(:parse_options!, ["-c", "config/busybee.yml"])
        expect(cli.instance_variable_get(:@parsed_options)[:config_file]).to eq("config/busybee.yml")
      end

      it "raises when --config and --runner-mode are both provided" do
        expect do
          described_class.new(["--config", "config/busybee.yml", "--runner-mode", "polling"])
        end.to raise_error(ArgumentError, /--config.*--runner-mode.*mutually exclusive/i)
      end

      it "raises when --config and positional worker args are both provided" do
        expect do
          described_class.new(["--config", "config/busybee.yml", "TestCLIWorker"])
        end.to raise_error(ArgumentError, /--config.*positional.*mutually exclusive/i)
      end

      it "allows process-wide flags alongside --config without mutual exclusion error" do
        yaml_path = write_yaml("process_wide.yml", <<~YAML)
          runner_mode: polling
          workers:
            TestCLIWorker: {}
        YAML
        expect do
          described_class.new(["-c", yaml_path, "-l", "json", "-n", "my-worker"])
        end.not_to raise_error
      end

      it "loads worker classes from YAML workers keys" do
        path = write_yaml("workers.yml", <<~YAML)
          workers:
            TestCLIWorker: {}
        YAML
        cli = described_class.new(["-c", path])
        expect(cli.worker_classes).to eq([TestCLIWorker])
      end

      it "loads multiple worker classes from YAML" do
        stub_const("SecondCLIWorker", second_worker_class)
        path = write_yaml("multi.yml", <<~YAML)
          workers:
            TestCLIWorker:
              runner_mode: polling
            SecondCLIWorker:
              runner_mode: streaming
        YAML
        cli = described_class.new(["-c", path])
        expect(cli.worker_classes).to contain_exactly(TestCLIWorker, SecondCLIWorker)
      end

      it "builds RuntimeConfig from YAML runner-scoped fields" do
        path = write_yaml("runner.yml", <<~YAML)
          runner_mode: hybrid
          max_jobs: 20
          workers:
            TestCLIWorker: {}
        YAML
        cli = described_class.new(["-c", path])
        expect(cli.runtime_config).to have_attributes(runner_mode: :hybrid, max_jobs: 20)
      end

      it "includes per-worker overrides from YAML in RuntimeConfig" do
        path = write_yaml("per_worker.yml", <<~YAML)
          runner_mode: hybrid
          workers:
            TestCLIWorker:
              runner_mode: polling
              max_jobs: 5
        YAML
        cli = described_class.new(["-c", path])
        resolved = cli.runtime_config.resolve_for(worker_class)
        expect(resolved).to have_attributes(runner_mode: :polling, max_jobs: 5)
      end

      it "merges CLI process-wide flags into YAML config" do
        path = write_yaml("merge.yml", <<~YAML)
          runner_mode: polling
          workers:
            TestCLIWorker: {}
        YAML
        cli = described_class.new(["-c", path, "-l", "json", "-n", "my-worker", "-a", "zeebe:26500"])
        expect(cli.runtime_config).to have_attributes(
          log_format: :json,
          worker_name: "my-worker",
          cluster_address: "zeebe:26500"
        )
      end

      it "applies process-wide flags to gem config" do
        path = write_yaml("apply.yml", <<~YAML)
          workers:
            TestCLIWorker: {}
        YAML
        described_class.new(["-c", path, "-l", "json"])
        expect(Busybee.log_format).to eq(:json)
      end

      it "raises when YAML specifies an unknown worker class" do
        path = write_yaml("bad_worker.yml", <<~YAML)
          workers:
            NonexistentWorker: {}
        YAML
        expect do
          described_class.new(["-c", path])
        end.to raise_error(Busybee::WorkerNotFound, /NonexistentWorker/)
      end

      it "raises when YAML has no workers key" do
        path = write_yaml("no_workers.yml", <<~YAML)
          runner_mode: polling
        YAML
        expect do
          described_class.new(["-c", path])
        end.to raise_error(Busybee::NoWorkersSpecified)
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

    context "with process-wide config application" do
      it "applies log_format to gem config" do
        described_class.new(["-l", "json", "TestCLIWorker"])
        expect(Busybee.log_format).to eq(:json)
      end

      it "applies worker_name to gem config" do
        described_class.new(["-n", "my-worker", "TestCLIWorker"])
        expect(Busybee.worker_name).to eq("my-worker")
      end

      it "applies cluster_address to gem config" do
        described_class.new(["-a", "zeebe.example.com:26500", "TestCLIWorker"])
        expect(Busybee.cluster_address).to eq("zeebe.example.com:26500")
      end

      it "does not override gem config when flags are not provided" do
        original_format = Busybee.log_format
        described_class.new(["TestCLIWorker"])
        expect(Busybee.log_format).to eq(original_format)
      end

      it "logs when overriding a value already set (e.g., by the Railtie)" do
        Busybee.log_format = :text
        logger = instance_double(Logger, info: nil, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        described_class.new(["-l", "json", "TestCLIWorker"])

        expect(logger).to have_received(:info).with(/--log-format overriding.*:text.*:json/)
      end

      it "does not log when no prior value was configured" do
        Busybee.instance_variable_set(:@worker_name, nil)
        logger = instance_double(Logger, info: nil, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        described_class.new(["-n", "my-worker", "TestCLIWorker"])

        expect(logger).not_to have_received(:info)
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
