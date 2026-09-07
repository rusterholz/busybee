# frozen_string_literal: true

require "concurrent"

require "busybee/runner"
require "busybee/runtime_config"

module Busybee
  class Runner
    # Multi runner — manages multiple worker types in a single process.
    # Each worker gets its own child runner (Polling/Streaming/Hybrid) running
    # in a dedicated thread via Concurrent::FixedThreadPool.
    #
    # Provides the same interface as single-worker runners (run!, stop!, kill!)
    # so the CLI can treat all runner types uniformly.
    class Multi < Runner
      attr_reader :runners

      def initialize(worker_classes, runtime_config: nil, client: nil)
        super(client: client)
        runtime_config ||= RuntimeConfig.new
        @runners = worker_classes.map do |worker_class|
          resolved = runtime_config.resolve_for(worker_class)
          Runner.for(worker_class, runtime_config: resolved, client: @client)
        end
        @thread_pool = Concurrent::FixedThreadPool.new(worker_classes.length)
        @thread_error = Concurrent::AtomicReference.new(nil)

        check_connection_pool_size(worker_classes)
      end

      def run!
        return if stopping?
        return unless @running.make_true # single-entry CAS, mirroring Runner#run!

        begin
          post_runners_to_pool
          @thread_pool.wait_for_termination

          err = @thread_error.get
          raise err if err
        ensure
          @running.make_false
        end
      end

      # Transparent: Multi manages child runners rather than being a worker, so it
      # fires no worker hooks of its own — hence winning the set-once reason gate
      # directly rather than through super, whose stop! fires T1. Each child fires
      # its own lifecycle hooks and takes the same reason, per worker class.
      def stop!(reason: :signal)
        @stop_reason.compare_and_set(nil, reason)
        @runners.each { |runner| runner.stop!(reason: reason) }
        @thread_pool.shutdown
      end

      def stopping?
        @runners.all?(&:stopping?)
      end

      def kill!(reason: :kill)
        super
        @runners.each { |runner| runner.kill!(reason: reason) }
        @thread_pool.kill
      end

      private

      # Two layers, because how hard to tear down depends on what killed the
      # child. A recoverable error leaves the process well enough to drain, so
      # the container stops gracefully. Below that line — NoMemoryError,
      # SystemStackError — a graceful stop would spend its time on the very
      # calls about to fail again, so the siblings are killed instead. Without
      # the second layer the pool thread simply died: nothing logged anywhere,
      # no cascade, and wait_for_termination never returning.
      def post_runners_to_pool
        @runners.each do |runner|
          @thread_pool.post do
            runner.run!
          rescue *RECOVERABLE_ERRORS => e
            record_child_failure(runner, e)
            stop!(reason: reason_for(e)) # container adopts the crash's reason (:crash/:gateway_error/:unhealthy)
          rescue Exception => e # rubocop:disable Lint/RescueException
            record_child_failure(runner, e)
            kill_children(reason_for(e))
          end
        end
      end

      # Record before cascading, always: a cascade can end this very thread, and
      # an unrecorded error would leave Multi#run! with nothing to re-raise —
      # reporting a clean shutdown for a container that crashed.
      def record_child_failure(runner, error)
        @thread_error.update { |prev| prev || error }
        Busybee.logger&.error(
          "Error in runner for #{runner_worker_name(runner)}: " \
          "[#{error.class}] #{error.message}"
        )
      end

      # Not #kill!: its @thread_pool.kill would end this very pool thread
      # mid-statement, leaving the pool unterminated and hanging the
      # wait_for_termination Multi#run! sits in. Killing the children lets each
      # run! return on its own. The reason stays the crash's — nobody forced this.
      def kill_children(reason)
        @stop_reason.compare_and_set(nil, reason)
        @runners.each { |runner| runner.kill!(reason: reason) }
        @thread_pool.shutdown
      end

      def runner_worker_name(runner)
        runner.instance_variable_get(:@worker_class)&.name || "(anonymous worker)"
      end

      def check_connection_pool_size(worker_classes)
        return unless defined?(ActiveRecord::Base)

        pool_size = ActiveRecord::Base.connection_pool.size
        worker_count = worker_classes.length

        if pool_size < worker_count
          Busybee.logger&.error(
            "Process #{Process.pid} is running #{worker_count} workers but the database " \
            "connection pool size is only #{pool_size}. This may cause connection timeout " \
            "errors. Adjust the pool size (usually via RAILS_MAX_THREADS) or reduce the " \
            "number of workers in this process."
          )
        else
          Busybee.logger&.info(
            "Process #{Process.pid} will run #{worker_count} workers with a database " \
            "connection pool size of #{pool_size}."
          )
        end
      end
    end
  end
end
