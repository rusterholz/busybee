# frozen_string_literal: true

require "busybee/runner"
require "busybee/runtime_config"
require "busybee/testing/client"
require "busybee/worker/shutdown"

module Busybee
  module Testing
    # A worker for specs: the real runner lifecycle, run synchronously in the
    # spec's own thread, with jobs handed in rather than fetched. Everything past
    # intake is the base Runner's own code — activation, execution, the hand-back
    # on shutdown, the teardown — so hooks fire as they do in production. What it
    # has no part in is transport: it reports no worker_mode, and its jobs no
    # source.
    #
    # @example Hold the worker lifecycle open around the jobs
    #   worker = start_test_worker(MyWorker)
    #   worker.activate([build_test_job(client: worker.client)])
    #   worker.stop!
    class Runner < Busybee::Runner
      attr_reader :client, :worker_class

      def initialize(worker_class, client: nil)
        super(worker_class, runtime_config: RuntimeConfig.new.resolve_for(worker_class),
                            client: client || Testing::Client.new)
      end

      # Fire on_worker_started and begin accepting jobs.
      #
      # @return [self]
      def start
        raise ArgumentError, "this worker has stopped; build another" if stopping?

        start!
        self
      end

      # Run each job through activation and execution, in order, as a runner does
      # with a fetched batch. A stop mid-batch hands the rest back; the teardown
      # then runs before this returns, and a Shutdown propagates from here as it
      # would from run!.
      #
      # @param jobs [Array<Busybee::Job>] built on this worker's client, not yet run
      # @return [Array<Busybee::Job>] the jobs
      def activate(jobs)
        refuse_unrunnable!(jobs)
        begin
          @activating = true
          @shutdown_error = nil
          jobs.each { |job| intake(job) }
          raise @shutdown_error if @shutdown_error
        ensure
          @activating = false
          teardown($!) if running? && (stopping? || $!)
        end
        jobs
      end

      # Fire on_worker_stop_requested, then — unless a batch is mid-run, whose
      # own teardown follows its hand-back — the closing moments.
      def stop!(reason: :signal)
        super
        teardown(nil) if running? && !@activating
      end

      def run!
        raise NotImplementedError, "#{self.class} runs synchronously: call start, activate and stop! instead"
      end

      private

      def worker_mode = nil

      # Polling's per-job intake, minus the fetch.
      def intake(job)
        activate_job(job, source: nil)
        stopping? ? handle_shutdown_job(job) : execute_job(job)
      rescue Busybee::Worker::Shutdown => e
        @shutdown_error = e
        stop!(reason: :unhealthy)
      end

      def refuse_unrunnable!(jobs)
        raise ArgumentError, "start the worker before activating jobs on it" unless running? && !stopping?

        jobs.each { |job| refuse_unrunnable_job!(job) }
      end

      def refuse_unrunnable_job!(job)
        unless job.client.equal?(@client)
          raise ArgumentError, "job #{job.key} resolves through a different client than this worker's; " \
                               "build it with build_test_job(client: worker.client)"
        end
        raise ArgumentError, "job #{job.key} already resolved (#{job.status})" unless job.ready?
        raise ArgumentError, "job #{job.key} already ran" if job.timestamps.execution_started_at
      end
    end
  end
end
