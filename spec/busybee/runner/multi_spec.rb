# frozen_string_literal: true

require "concurrent"
require "ostruct"

RSpec.describe Busybee::Runner::Multi do
  let(:client) { instance_double(Busybee::Client) }

  let(:polling_worker) do
    Class.new(Busybee::Worker) do
      job_type "test_worker_1"
      def perform; end
    end
  end

  let(:streaming_worker) do
    Class.new(Busybee::Worker) do
      job_type "test_worker_2"
      def perform; end
    end
  end

  let(:worker_classes) { [polling_worker, streaming_worker] }
  let(:thread_pool) { Concurrent::FixedThreadPool.new(worker_classes.length) }

  before do
    allow(Concurrent::FixedThreadPool).to receive(:new).and_return(thread_pool)
    stub_const("TestMultiWorker1", polling_worker)
    stub_const("TestMultiWorker2", streaming_worker)
  end

  describe "#initialize" do
    it "creates a child runner for each worker class" do
      multi = described_class.new(worker_classes, client: client)

      expect(multi.runners.length).to eq(2)
      expect(multi.runners).to all(be_a(Busybee::Runner))
    end

    it "shares the same client across all child runners" do
      multi = described_class.new(worker_classes, client: client)

      expect(multi.runners).to all(satisfy { |r| r.instance_variable_get(:@client).equal?(client) })
    end

    it "resolves worker mode per worker class" do
      polling_worker.worker_mode :polling
      streaming_worker.worker_mode :streaming

      multi = described_class.new(worker_classes, client: client)

      expect(multi.runners[0]).to be_a(Busybee::Runner::Polling)
      expect(multi.runners[1]).to be_a(Busybee::Runner::Streaming)
    end

    it "applies runtime_config override to all child runners" do
      rc = Busybee::RuntimeConfig.new(worker_mode: :polling)
      multi = described_class.new(worker_classes, runtime_config: rc, client: client)

      expect(multi.runners).to all(be_a(Busybee::Runner::Polling))
    end

    it "resolves per-worker overrides from runtime_config" do
      rc = Busybee::RuntimeConfig.new(
        worker_mode: :hybrid,
        workers: {
          "TestMultiWorker1" => { worker_mode: :polling },
          "TestMultiWorker2" => { worker_mode: :streaming }
        }
      )
      multi = described_class.new(worker_classes, runtime_config: rc, client: client)

      expect(multi.runners[0]).to be_a(Busybee::Runner::Polling)
      expect(multi.runners[1]).to be_a(Busybee::Runner::Streaming)
    end

    it "creates a thread pool sized to the number of workers" do
      described_class.new(worker_classes, client: client)

      expect(Concurrent::FixedThreadPool).to have_received(:new).with(2)
    end

    it "inherits Runner interface" do
      multi = described_class.new(worker_classes, client: client)

      expect(multi).to be_a(Busybee::Runner)
      expect(multi.running?).to be false
    end

    describe "ActiveRecord connection pool check" do
      context "when ActiveRecord is not defined" do
        it "does not log anything" do
          logger = instance_double(Logger, error: nil, info: nil)
          allow(Busybee).to receive(:logger).and_return(logger)

          described_class.new(worker_classes, client: client)

          expect(logger).not_to have_received(:error)
          expect(logger).not_to have_received(:info)
        end
      end

      context "when ActiveRecord is defined" do
        let(:mock_pool) { OpenStruct.new(size: pool_size) } # rubocop:disable Style/OpenStructUse
        let(:mock_base) { OpenStruct.new(connection_pool: mock_pool) } # rubocop:disable Style/OpenStructUse
        let(:logger) { instance_double(Logger, error: nil, info: nil) }

        before do
          allow(Busybee).to receive(:logger).and_return(logger)
          stub_const("ActiveRecord::Base", mock_base)
        end

        context "when pool size is smaller than worker count" do
          let(:pool_size) { 1 }

          it "logs an error" do
            described_class.new(worker_classes, client: client)

            expect(logger).to have_received(:error).with(/pool size is only 1/)
          end
        end

        context "when pool size is sufficient" do
          let(:pool_size) { 5 }

          it "logs an info message" do
            described_class.new(worker_classes, client: client)

            expect(logger).to have_received(:info).with(/2 workers with a database connection pool size of 5/)
          end
        end
      end
    end
  end

  describe "#run!" do
    before do
      allow(thread_pool).to receive(:post).and_call_original
      allow(thread_pool).to receive(:wait_for_termination).and_call_original
      allow(thread_pool).to receive(:shutdown).and_call_original
    end

    it "posts each runner to the thread pool and waits for termination" do
      multi = described_class.new(worker_classes, client: client)

      multi.runners.each do |runner|
        allow(runner).to receive(:run!) {
          sleep(0.1)
          thread_pool.shutdown
        }
      end

      multi.run!

      expect(thread_pool).to have_received(:post).twice
      expect(thread_pool).to have_received(:wait_for_termination)
      expect(multi.runners).to all(have_received(:run!).once)
    end

    it "sets running? during execution" do
      multi = described_class.new(worker_classes, client: client)

      multi.runners.each do |runner|
        allow(runner).to receive(:run!) {
          expect(multi.running?).to be true
          thread_pool.shutdown
        }
      end

      multi.run!

      expect(multi.running?).to be false
    end

    it "does not enter the pool if already stopping" do
      multi = described_class.new(worker_classes, client: client)
      multi.stop!

      multi.run!

      expect(thread_pool).not_to have_received(:post)
    end

    it "sets running? to false even when an error is raised" do
      multi = described_class.new(worker_classes, client: client)

      multi.runners.each do |runner|
        allow(runner).to receive(:run!).and_raise(RuntimeError, "boom")
      end

      expect { multi.run! }.to raise_error(RuntimeError, "boom")
      expect(multi.running?).to be false
    end

    context "when a runner raises an exception" do
      it "stops all runners and re-raises after pool termination" do
        multi = described_class.new(worker_classes, client: client)
        first_runner, second_runner = multi.runners

        allow(first_runner).to receive(:run!).and_return(true)
        allow(second_runner).to receive(:run!).and_raise(StandardError, "worker crashed")

        expect { multi.run! }.to raise_error(StandardError, "worker crashed")

        expect(multi.runners).to all(be_stopping)
      end

      it "cascades :crash to the container when a runner dies of an unrelated error" do
        multi = described_class.new(worker_classes, client: client)
        first_runner, second_runner = multi.runners
        multi.runners.each { |r| allow(r).to receive(:stop!) }
        allow(first_runner).to receive(:run!).and_return(true)
        allow(second_runner).to receive(:run!).and_raise(StandardError, "worker crashed")

        expect { multi.run! }.to raise_error(StandardError, "worker crashed")

        expect(multi.runners).to all(have_received(:stop!).with(reason: :crash))
      end

      it "cascades :unhealthy when a runner goes down via Worker::Shutdown" do
        multi = described_class.new(worker_classes, client: client)
        first_runner, second_runner = multi.runners
        multi.runners.each { |r| allow(r).to receive(:stop!) }
        allow(first_runner).to receive(:run!).and_return(true)
        allow(second_runner).to receive(:run!).and_raise(Busybee::Worker::Shutdown.new(worker: streaming_worker))

        expect { multi.run! }.to raise_error(Busybee::Worker::Shutdown)

        expect(multi.runners).to all(have_received(:stop!).with(reason: :unhealthy))
      end

      it "logs the error with worker name" do
        logger = instance_double(Logger, error: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        multi = described_class.new(worker_classes, client: client)
        allow(multi.runners[0]).to receive(:run!).and_return(true)
        allow(multi.runners[1]).to receive(:run!).and_raise(StandardError, "kaboom")

        expect { multi.run! }.to raise_error(StandardError)

        expect(logger).to have_received(:error).with(/TestMultiWorker2.*kaboom/)
      end
    end

    context "when multiple runners raise exceptions" do
      it "captures only the first error (first-error-wins)" do
        multi = described_class.new(worker_classes, client: client)
        trigger = Concurrent::IVar.new

        allow(multi.runners[0]).to receive(:run!) {
          raise(StandardError.new("first!").tap { trigger.set(true) })
        }
        allow(multi.runners[1]).to receive(:run!) {
          trigger.wait
          raise StandardError, "second!"
        }

        expect { multi.run! }.to raise_error(StandardError, "first!")
      end
    end
  end

  describe "#stop!" do
    after { Busybee::Hooks.reset! }

    it "stops all child runners and shuts down the thread pool" do
      multi = described_class.new(worker_classes, client: client)
      multi.runners.each { |r| allow(r).to receive(:stop!) }
      allow(thread_pool).to receive(:shutdown)

      multi.stop!

      expect(multi.runners).to all(have_received(:stop!))
      expect(thread_pool).to have_received(:shutdown)
    end

    it "cascades the stop reason to every child" do
      multi = described_class.new(worker_classes, client: client)
      multi.runners.each { |r| allow(r).to receive(:stop!) }
      allow(thread_pool).to receive(:shutdown)

      multi.stop!(reason: :rollover)

      expect(multi.runners).to all(have_received(:stop!).with(reason: :rollover))
    end

    it "fires no worker hooks of its own (transparent — children fire theirs)" do
      fired = []
      Busybee.on_worker_stop_requested { fired << :multi }
      multi = described_class.new(worker_classes, client: client)
      multi.runners.each { |r| allow(r).to receive(:stop!) }
      allow(thread_pool).to receive(:shutdown)

      multi.stop!

      expect(fired).to be_empty
    end
  end

  describe "#stopping?" do
    it "returns false when no runners are stopping" do
      multi = described_class.new(worker_classes, client: client)

      expect(multi).not_to be_stopping
    end

    it "returns false when only some runners are stopping" do
      multi = described_class.new(worker_classes, client: client)
      multi.runners.first.stop!

      expect(multi).not_to be_stopping
    end

    it "returns true when all runners are stopping" do
      multi = described_class.new(worker_classes, client: client)
      multi.stop!

      expect(multi).to be_stopping
    end
  end

  describe "#kill!" do
    it "kills all child runners and the thread pool" do
      multi = described_class.new(worker_classes, client: client)
      multi.runners.each { |r| allow(r).to receive(:kill!).and_call_original }
      allow(thread_pool).to receive(:kill)

      multi.kill!

      expect(multi.runners).to all(have_received(:kill!))
      expect(thread_pool).to have_received(:kill)
    end

    it "cascades :kill to children through super's stop!" do
      multi = described_class.new(worker_classes, client: client)
      multi.runners.each do |r|
        allow(r).to receive(:stop!)
        allow(r).to receive(:kill!)
      end
      allow(thread_pool).to receive(:shutdown)
      allow(thread_pool).to receive(:kill)

      multi.kill!

      expect(multi.runners).to all(have_received(:stop!).with(reason: :kill))
    end
  end
end
