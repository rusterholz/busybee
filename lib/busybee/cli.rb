# frozen_string_literal: true

require "optparse"

require "busybee/client"
require "busybee/error"
require "busybee/runner"
require "busybee/runtime_config"
require "busybee/version"
require "busybee/worker"

module Busybee
  class CLI
    attr_reader :runtime_config, :worker_class_names, :worker_classes

    # Signals we trap to begin a graceful stop.
    STOP_SIGNALS = %w[INT QUIT TERM].freeze

    def self.main(args)
      new(args).run
    end

    def initialize(args)
      @worker_class_names = []
      @parsed_options = {}
      parse_options!(args.dup)
      load_environment!
      extract_workers_from_yaml! if @parsed_options[:config_file]
      load_workers!
      build_config!
      apply_global_config!
    end

    def run
      @runner = Runner.for(*@worker_classes, runtime_config: @runtime_config, client: client)
      setup_signal_handlers!
      @runner.run!
    end

    private

    def client
      @client ||= Busybee::Client.new
    end

    def handle_signal(signal)
      if @runner.stopping?
        @runner.kill!
        exit!(1)
      else
        @runner.stop!(reason: :"sig#{signal.downcase}")
      end
    end

    def setup_signal_handlers!
      STOP_SIGNALS.each do |signal|
        trap(signal) do
          Thread.new { handle_signal(signal) }.join
        end
      end
    end

    def load_environment!
      return if ENV["BUSYBEE_SKIP_RAILS"]

      begin
        require "rails"
      rescue LoadError
        return
      end

      # Register the Railtie before config/environment's initialize!: busybee.rb's
      # guarded self-require ran before Rails (exe requires busybee first), so
      # without this every config.x.busybee.* is silently dropped in CLI workers.
      require "busybee/railtie"
      require "./config/environment"
    rescue StandardError, LoadError => e
      Busybee.logger&.error("Failed to load Rails environment: [#{e.class}] #{e.message}. " \
                            "Set BUSYBEE_SKIP_RAILS=1 to skip Rails loading.")
    end

    def extract_workers_from_yaml!
      @yaml_kwargs = RuntimeConfig.parse_yaml(@parsed_options[:config_file])
      @worker_class_names = (@yaml_kwargs[:workers] || {}).keys
    end

    def build_config!
      if @yaml_kwargs
        kwargs = @yaml_kwargs.dup
        # Merge CLI process-wide flags into YAML-sourced kwargs
        %i[log_format worker_name cluster_address].each do |field|
          kwargs[field] = @parsed_options[field] if @parsed_options[field]
        end
        @runtime_config = RuntimeConfig.new(**kwargs)
      else
        @runtime_config = RuntimeConfig.new(**@parsed_options)
      end
    end

    def load_workers!
      raise Busybee::NoWorkersSpecified, "No worker classes specified" if @worker_class_names.empty?

      @worker_classes = @worker_class_names.map do |name|
        Kernel.const_get(name)
      rescue NameError => e
        raise Busybee::WorkerNotFound, "Could not load worker class '#{name}': #{e.message}"
      end
    end

    def parse_options!(args)
      option_parser.parse!(args)
      @worker_class_names = args
      validate_config_exclusions!
    end

    def validate_config_exclusions!
      return unless @parsed_options[:config_file]

      if @parsed_options[:worker_mode]
        raise ArgumentError, "--config and --worker-mode are mutually exclusive. " \
                             "Set worker_mode in the YAML config file instead."
      end

      return if @worker_class_names.empty?

      raise ArgumentError, "--config and positional worker args are mutually exclusive. " \
                           "List workers in the YAML config file instead."
    end

    def option_parser # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      OptionParser.new do |opts|
        opts.banner = "Usage: busybee [options] WorkerClass [WorkerClass ...]"

        opts.on("-v", "--version", "Print version and exit") do
          puts Busybee::VERSION
          exit
        end

        opts.on("-h", "--help", "Print this help message and exit") do
          puts opts
          exit
        end

        opts.on("-c", "--config FILE", "YAML configuration file") do |file|
          @parsed_options[:config_file] = file
        end

        opts.on("-m", "--worker-mode MODE", "Worker mode (polling, streaming, hybrid)") do |mode|
          @parsed_options[:worker_mode] = mode.to_sym
        end

        opts.on("-l", "--log-format FORMAT", "Log format (text, json)") do |format|
          @parsed_options[:log_format] = format.to_sym
        end

        opts.on("-n", "--worker-name NAME", "Worker name for identification") do |name|
          @parsed_options[:worker_name] = name
        end

        opts.on("-a", "--cluster-address ADDR", "Cluster address (host:port)") do |addr|
          @parsed_options[:cluster_address] = addr
        end
      end
    end

    # Applies process-wide flags to gem-level config before runners start.
    # Only sets values that were explicitly provided via CLI flags.
    # Logs when overriding a value already set (e.g., by the Railtie).
    def apply_global_config!
      apply_global_setting!(:log_format)
      apply_global_setting!(:worker_name)
      apply_global_setting!(:cluster_address)
    end

    def apply_global_setting!(field)
      cli_value = @runtime_config.public_send(field)
      return unless cli_value

      existing = Busybee.instance_variable_get(:"@#{field}")
      if existing
        flag = "--#{field.to_s.tr('_', '-')}"
        Busybee.logger&.info("#{flag} overriding configured value: #{existing.inspect} → #{cli_value.inspect}")
      end
      Busybee.public_send(:"#{field}=", cli_value)
    end
  end
end
