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
      @runner_mode = nil
      parse_options!(args.dup)
      load_environment!
      load_workers!
      @runtime_config = RuntimeConfig.new(runner_mode: @runner_mode)
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

    def option_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: busybee [options] WorkerClass [WorkerClass ...]"

        opts.on("--version", "Print version and exit") do
          puts Busybee::VERSION
          exit
        end

        opts.on("-h", "--help", "Print this help message and exit") do
          puts opts
          exit
        end

        opts.on("-m", "--runner-mode MODE", "Runner mode (polling, streaming, hybrid)") do |mode|
          @runner_mode = mode.to_sym
        end
      end
    end
  end
end
