# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"
require "concurrent"
require "optparse"

require "busybee/client"
require "busybee/configure"
require "busybee/durations"
require "busybee/error"
require "busybee/logging"
require "busybee/runner"
require "busybee/runtime_config"
require "busybee/version"
require "busybee/worker"

module Busybee
  class CLI
    attr_reader :runtime_config, :worker_class_names, :worker_classes

    # Signals we trap to begin a graceful stop.
    STOP_SIGNALS = %w[INT QUIT TERM].freeze

    delegate :exit_immediately?, to: :"Busybee::Runner", private: true

    def self.main(args) = new(args).run

    def initialize(args)
      @signalled = Concurrent::AtomicBoolean.new(false) # before any trap can fire
      @worker_class_names = []
      @parsed_options = {}
      parse_options!(args.dup)
      load_environment!
      extract_workers_from_yaml! if @parsed_options[:config_file]
      load_workers!
      build_config!
      apply_global_config!
    end

    # Exits 1 once the run has returned if the process must exit immediately, an
    # error having struck somewhere that raised nothing here.
    def run
      @runner = Runner.for(*@worker_classes, runtime_config: @runtime_config, client: client)
      setup_signal_handlers!
      begin
        @runner.run!
      ensure
        join_signal_threads
      end
      exit(1) if exit_immediately?
    end

    private

    def client
      @client ||= Busybee::Client.new
    end

    # The first signal stops; any later one forces. The CLI's own set-once flag
    # decides, since a runner's stopping? can lag a stop still under way.
    def handle_signal(signal)
      return @runner.stop!(reason: :"sig#{signal.downcase}") if @signalled.make_true

      force_exit
    end

    # A kill's own stop can reach a worker not yet stopped and hang or fail in its
    # on_worker_stop_requested, so it gets a bounded wait, then the exit regardless.
    def force_exit
      Thread.new { @runner.kill! }.join(Busybee::Durations.seconds_from(Busybee.shutdown_wait_timeout))
    ensure
      exit!(1)
    end

    # The trap runs on the main thread, on top of whatever it interrupted, a
    # write holding the logger's lock included; so the handling happens on a
    # thread of its own, and the trap returns without waiting for it.
    def setup_signal_handlers!
      @signal_threads = []
      STOP_SIGNALS.each do |signal|
        trap(signal) { @signal_threads << Thread.new { handle_signal(signal) } }
      end
    end

    # Ruby kills unjoined threads at exit, so a stop announcement still running
    # on a signal's thread is waited for, up to shutdown_wait_timeout, or not at
    # all once the process must exit immediately. Either way, joining re-raises
    # the error a thread already died of.
    def join_signal_threads
      wait = exit_immediately? ? 0 : Busybee::Durations.seconds_from(Busybee.shutdown_wait_timeout)
      @signal_threads&.each { |thread| thread.join(wait) }
    end

    def load_environment!
      return if ENV["BUSYBEE_SKIP_RAILS"].present?

      begin
        require "rails"
      rescue LoadError
        return
      end

      require "busybee/railtie" # defensive: busybee.rb's :before_configuration hook registers it already
      require "./config/environment"
    rescue StandardError, LoadError => e
      Logging.error("Failed to load Rails environment: [#{e.class}] #{e.message}. " \
                    "Set BUSYBEE_SKIP_RAILS=1 to skip Rails loading.", error: e)
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

    def option_parser
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

        opts.on("-m", "--worker-mode MODE", "Worker mode (#{Configure::VALID_WORKER_MODES.join(', ')})") do |mode|
          @parsed_options[:worker_mode] = mode.to_sym
        end

        process_wide_options(opts)
      end
    end

    def process_wide_options(opts)
      opts.on("-l", "--log-format FORMAT", "Log format (#{Configure::VALID_LOG_FORMATS.join(', ')})") do |format|
        @parsed_options[:log_format] = format.to_sym
      end

      opts.on("-n", "--worker-name NAME", "Worker name for identification") do |name|
        @parsed_options[:worker_name] = name
      end

      opts.on("-a", "--cluster-address ADDR", "Cluster address (host:port)") do |addr|
        @parsed_options[:cluster_address] = addr
      end
    end

    # Applies process-wide flags, and YAML's top-level shutdown_wait_timeout, to
    # gem-level config before runners start. Only sets values explicitly provided.
    # Logs when overriding a value already set (e.g., by the Railtie).
    def apply_global_config!
      apply_global_setting!(:log_format)
      apply_global_setting!(:worker_name)
      apply_global_setting!(:cluster_address)
      apply_global_setting!(:shutdown_wait_timeout, source: "YAML shutdown_wait_timeout")
    end

    def apply_global_setting!(field, source: "--#{field.to_s.tr('_', '-')}")
      cli_value = @runtime_config.public_send(field)
      return unless cli_value

      # The raw slot, not the reader: that falls back to ENV and defaults, which nothing configured.
      existing = Busybee.instance_variable_get(:"@#{field}")
      Logging.info("#{source} overriding configured value: #{existing.inspect} → #{cli_value.inspect}") if existing
      Busybee.public_send(:"#{field}=", cli_value)
    end
  end
end
