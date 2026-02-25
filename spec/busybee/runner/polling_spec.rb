# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Polling do
  subject(:runner) { described_class.new(worker_class, runtime_config: runtime_config, client: client) }

  let(:client) { instance_double(Busybee::Client) }
  let(:job) { instance_double(Busybee::Job, key: 1, retries: 3, ready?: true) }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"

      def perform
        # no-op
      end
    end
  end

  describe "#initialize" do
    it "stores the worker class" do
      expect(runner.instance_variable_get(:@worker_class)).to be(worker_class)
    end

    it "inherits Runner interface" do
      expect(runner).to be_a(Busybee::Runner)
      expect(runner.stopping?).to be false
      expect(runner.running?).to be false
    end
  end

  describe "#run!" do
    it "fetches jobs via client.with_each_job with resolved options" do
      allow(client).to receive(:with_each_job) do |type, **opts, &_block|
        expect(type).to eq("test_worker")
        expect(opts).to include(:max_jobs, :request_timeout, :job_timeout)
        runner.stop!
        0
      end

      runner.run!

      expect(client).to have_received(:with_each_job)
    end

    it "does not enter the loop if already stopping" do
      allow(client).to receive(:with_each_job)

      runner.stop!
      runner.run!

      expect(client).not_to have_received(:with_each_job)
    end

    it "processes jobs via worker_class.perform_job" do
      call_count = 0
      allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
        if call_count == 0
          call_count += 1
          block.call(job)
        end
        runner.stop!
        0
      end
      allow(worker_class).to receive(:perform_job)

      runner.run!

      expect(worker_class).to have_received(:perform_job).with(job)
    end

    it "sets running? to true during execution and false after" do
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        expect(runner.running?).to be true
        runner.stop!
        0
      end

      runner.run!

      expect(runner.running?).to be false
    end

    it "sets running? to false even when an error is raised" do
      allow(client).to receive(:with_each_job).and_raise(RuntimeError, "boom")

      expect { runner.run! }.to raise_error(RuntimeError, "boom")
      expect(runner.running?).to be false
    end

    it "stops the loop when stop! is called" do
      loop_count = 0
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        loop_count += 1
        runner.stop! if loop_count >= 2
        0
      end

      runner.run!

      expect(loop_count).to eq(2)
      expect(client).to have_received(:with_each_job).exactly(2).times
    end

    it "passes job_type from worker configuration" do
      allow(client).to receive(:with_each_job) do |type, **_opts, &_block|
        expect(type).to eq("test_worker")
        runner.stop!
        0
      end

      runner.run!
    end

    it "passes worker DSL overrides in polling options" do
      worker_class.polling max_jobs: 10, request_timeout: 30_000
      worker_class.job_timeout 120_000

      allow(client).to receive(:with_each_job) do |_type, **opts, &_block|
        expect(opts[:max_jobs]).to eq(10)
        expect(opts[:request_timeout]).to eq(30_000)
        expect(opts[:job_timeout]).to eq(120_000)
        runner.stop!
        0
      end

      runner.run!
    end

    it "passes gem defaults when worker has no polling config" do
      allow(client).to receive(:with_each_job) do |_type, **opts, &_block|
        expect(opts[:max_jobs]).to eq(Busybee::Defaults::DEFAULT_MAX_JOBS)
        expect(opts[:request_timeout]).to eq(Busybee.default_job_request_timeout)
        expect(opts[:job_timeout]).to eq(Busybee.default_job_lock_timeout)
        runner.stop!
        0
      end

      runner.run!
    end

    context "when worker raises Busybee::Worker::Shutdown" do
      let(:cause) { RuntimeError.new("DB connection lost") }
      let(:shutdown_error) { Busybee::Worker::Shutdown.new("shutting down", worker: worker_class) }

      it "stores the error, stops, and re-raises after clean exit" do
        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          block.call(job)
          0
        end
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "does not process more jobs after Shutdown" do
        calls = 0
        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          calls += 1
          block.call(job) if calls == 1
          0
        end
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(calls).to eq(1)
      end
    end

    context "when GRPC backpressure errors occur" do
      it "sleeps and retries on GRPC::ResourceExhausted" do
        call_count = 0
        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          call_count += 1
          raise GRPC::ResourceExhausted, "rate limited" if call_count == 1

          runner.stop!
          0
        end
        allow(runner).to receive(:sleep) # rubocop:disable RSpec/SubjectStub

        runner.run!

        expect(runner).to have_received(:sleep).with(runtime_config.backpressure_delay) # rubocop:disable RSpec/SubjectStub
        expect(call_count).to eq(2)
      end

      it "lets GRPC::Unavailable propagate (client already retried)" do
        allow(client).to receive(:with_each_job).and_raise(GRPC::Unavailable, "service down")

        expect { runner.run! }.to raise_error(GRPC::Unavailable)
        expect(runner.running?).to be false
      end
    end

    context "when graceful shutdown is triggered" do
      it "fails remaining yielded jobs with preserved retries" do # rubocop:disable RSpec/ExampleLength
        jobs = [
          instance_double(Busybee::Job, key: 1, retries: 3, ready?: true),
          instance_double(Busybee::Job, key: 2, retries: 5, ready?: true)
        ]
        allow(jobs[0]).to receive(:fail!)
        allow(jobs[1]).to receive(:fail!)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          block.call(jobs[0])
          runner.stop!
          block.call(jobs[1])
          0
        end
        allow(worker_class).to receive(:perform_job)

        runner.run!

        expect(worker_class).to have_received(:perform_job).with(jobs[0]).once
        expect(worker_class).not_to have_received(:perform_job).with(jobs[1])
        expect(jobs[1]).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 5,
          backoff: Busybee.default_fail_job_backoff
        )
      end

      it "uses the worker's configured backoff during shutdown" do
        worker_class.backoff 30_000
        job_to_fail = instance_double(Busybee::Job, key: 1, retries: 3, ready?: true)
        allow(job_to_fail).to receive(:fail!)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          runner.stop!
          block.call(job_to_fail)
          0
        end

        runner.run!

        expect(job_to_fail).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 3,
          backoff: 30_000
        )
      end

      it "logs a warning when failing a shutdown job raises an error" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        bad_job = instance_double(Busybee::Job, key: 99, retries: 1, ready?: true)
        allow(bad_job).to receive(:fail!).and_raise(StandardError, "grpc gone")

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          runner.stop!
          block.call(bad_job)
          0
        end

        runner.run!

        expect(logger).to have_received(:warn).with(/Failed to fail job 99 during shutdown.*grpc gone/)
      end
    end
  end
end
