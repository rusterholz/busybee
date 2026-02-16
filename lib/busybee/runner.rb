# frozen_string_literal: true

require "concurrent"

module Busybee
  # Base class for all runner types. Provides shared interface (run!, stop!, stopping?,
  # running?, kill!) and the Runner.for factory method for mode resolution.
  #
  # Subclasses must implement #run! to define their job-fetching loop.
  class Runner
    def initialize(client: nil)
      @client = client || Busybee::Client.new
      @stop_requested = Concurrent::AtomicBoolean.new(false)
      @running = Concurrent::AtomicBoolean.new(false)
    end

    # Blocks until stopped or error. Subclasses must implement.
    def run!
      raise NotImplementedError
    end

    # Signals graceful shutdown. Thread-safe (called from signal handler).
    def stop!
      @stop_requested.make_true
    end

    # True if stop! has been called.
    def stopping?
      @stop_requested.true?
    end

    # True if run! is actively executing.
    def running?
      @running.true?
    end

    # Force shutdown. Base: calls stop!. Multi overrides to also kill thread pool.
    def kill!
      stop!
    end

    class << self
      # Factory method. Resolves runner mode from precedence chain and returns
      # the appropriate runner instance.
      #
      # Mode resolution (lowest to highest priority):
      #   1. Gem default: Busybee.default_runner_mode
      #   2. Worker DSL: worker_class.configuration.runner_mode
      #   3. Explicit override: mode: parameter (from CLI/YAML)
      def for(*worker_classes, mode: nil, client: nil)
        client ||= Busybee::Client.new

        if worker_classes.length > 1
          Multi.new(worker_classes, mode: mode, client: client)
        else
          runner_class_for(worker_classes.first, mode: mode).new(worker_classes.first, client: client)
        end
      end

      private

      def runner_class_for(worker_class, mode: nil)
        resolved_mode = mode || worker_class.configuration.runner_mode || Busybee.default_runner_mode

        case resolved_mode
        when :polling then Polling
        when :streaming then Streaming
        when :hybrid then Hybrid
        else
          raise ArgumentError,
                "Invalid runner mode: #{resolved_mode.inspect}. Valid: :polling, :streaming, :hybrid"
        end
      end
    end

    private

    # Fails a job during graceful shutdown, preserving its retry count.
    # Uses the greater of runner_shutdown_backoff and the worker's configured backoff,
    # ensuring job types that need long backoffs always get them.
    def handle_shutdown_job(job)
      job.fail!(
        "Worker shutting down",
        retries: job.retries,
        backoff: shutdown_backoff
      )
    rescue StandardError => e
      Busybee.logger&.warn("Failed to fail job #{job.key} during shutdown: #{e.message}")
    end

    def shutdown_backoff
      worker_backoff = @worker_class.configuration.backoff || Busybee.default_fail_job_backoff
      [Busybee.runner_shutdown_backoff, worker_backoff].max
    end
  end
end

require "busybee/runner/polling"
require "busybee/runner/streaming"
