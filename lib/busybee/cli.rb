# frozen_string_literal: true

require "optparse"

module Busybee
  class CLI
    attr_reader :runtime_config, :worker_class_names, :worker_classes

    def self.main(args)
      new(args).run
    end

    def initialize(args)
      @worker_class_names = []
      @parsed_options = {}
      parse_options!(args.dup)
      load_environment!
      load_workers!
      @runtime_config = RuntimeConfig.new(**@parsed_options)
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

    def handle_signal(_signal)
      if @runner.stopping?
        @runner.kill!
        exit!(1)
      else
        @runner.stop!
      end
    end

    def setup_signal_handlers!
      %w[INT QUIT TERM].each do |signal|
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

      require "./config/environment"
    rescue StandardError => e
      Busybee.logger&.error("Failed to load Rails environment: [#{e.class}] #{e.message}. " \
                            "Set BUSYBEE_SKIP_RAILS=1 to skip Rails loading.")
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

        opts.on("-m", "--runner-mode MODE", "Runner mode (polling, streaming, hybrid)") do |mode|
          @parsed_options[:runner_mode] = mode.to_sym
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
