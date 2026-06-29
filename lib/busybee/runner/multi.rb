# frozen_string_literal: true

require "concurrent"

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

      def stop!
        # Multi is transparent — it manages child runners rather than being a
        # worker, so it fires no worker hooks of its own. Flip the flag directly
        # instead of via super (whose stop! now fires on_worker_stop_requested);
        # each child fires its own lifecycle hooks per worker-class.
        @stop_requested.make_true
        @runners.each(&:stop!)
        @thread_pool.shutdown
      end

      def stopping?
        @runners.all?(&:stopping?)
      end

      def kill!
        super
        @runners.each(&:kill!)
        @thread_pool.kill
      end

      private

      def post_runners_to_pool
        @runners.each do |runner|
          @thread_pool.post do
            runner.run!
          rescue StandardError => e
            @thread_error.update { |prev| prev || e }
            Busybee.logger&.error(
              "Error in runner for #{runner_worker_name(runner)}: " \
              "[#{e.class}] #{e.message}"
            )
            stop!
          end
        end
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
