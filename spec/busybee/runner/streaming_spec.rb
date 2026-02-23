# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner::Streaming do
  subject(:runner) { described_class.new(worker_class, client: client) }

  let(:client) { instance_double(Busybee::Client) }
  let(:job) { instance_double(Busybee::Job, key: 1, retries: 3, ready?: true) }
  let(:stream) { instance_double(Busybee::JobStream) }

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"
      streaming queue: false

      def perform
        # no-op
      end
    end
  end

  before do
    allow(stream).to receive(:close)
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
    it "opens a job stream with resolved options" do
      allow(client).to receive(:open_job_stream) do |type, **opts|
        expect(type).to eq("test_worker")
        expect(opts).to include(:job_timeout)
        allow(stream).to receive(:each)
        stream
      end

      runner.run!

      expect(client).to have_received(:open_job_stream)
    end

    it "does not open a stream if already stopping" do
      allow(client).to receive(:open_job_stream)

      runner.stop!
      runner.run!

      expect(client).not_to have_received(:open_job_stream)
    end

    it "processes jobs via worker_class.perform_job" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each).and_yield(job)
        stream
      end
      allow(worker_class).to receive(:perform_job) do
        runner.stop!
      end

      runner.run!

      expect(worker_class).to have_received(:perform_job).with(job)
    end

    it "sets running? to true during execution and false after" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each) do
          expect(runner.running?).to be true
        end
        stream
      end

      runner.run!

      expect(runner.running?).to be false
    end

    it "sets running? to false even when an error is raised" do
      allow(client).to receive(:open_job_stream).and_raise(RuntimeError, "boom")

      expect { runner.run! }.to raise_error(RuntimeError, "boom")
      expect(runner.running?).to be false
    end

    it "passes job_type from worker configuration" do
      allow(client).to receive(:open_job_stream) do |type, **_opts|
        expect(type).to eq("test_worker")
        allow(stream).to receive(:each)
        stream
      end

      runner.run!
    end

    it "passes worker DSL job_timeout override in streaming options" do
      worker_class.job_timeout 120_000

      allow(client).to receive(:open_job_stream) do |_type, **opts|
        expect(opts[:job_timeout]).to eq(120_000)
        allow(stream).to receive(:each)
        stream
      end

      runner.run!
    end

    it "passes gem default job_timeout when worker has no override" do
      allow(client).to receive(:open_job_stream) do |_type, **opts|
        expect(opts[:job_timeout]).to eq(Busybee.default_job_lock_timeout)
        allow(stream).to receive(:each)
        stream
      end

      runner.run!
    end

    it "closes the stream in ensure even on normal exit" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each)
        stream
      end

      runner.run!

      expect(stream).to have_received(:close)
    end

    it "closes the stream in ensure on error" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each).and_raise(RuntimeError, "stream broke")
        stream
      end

      expect { runner.run! }.to raise_error(RuntimeError, "stream broke")
      expect(stream).to have_received(:close)
    end

    context "when worker raises Busybee::Worker::Shutdown" do
      let(:shutdown_error) { Busybee::Worker::Shutdown.new("shutting down", worker: worker_class) }

      it "stores the error, stops, and re-raises after clean exit" do
        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each).and_yield(job)
          stream
        end
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "does not process more jobs after Shutdown" do
        jobs = [
          instance_double(Busybee::Job, key: 1, retries: 3, ready?: true),
          instance_double(Busybee::Job, key: 2, retries: 5, ready?: true)
        ]
        allow(jobs[1]).to receive(:fail!)

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each).and_yield(jobs[0]).and_yield(jobs[1])
          stream
        end
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(worker_class).to have_received(:perform_job).once
      end
    end

    context "when stream ends without stop!" do
      it "exits cleanly" do
        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) # yields nothing, returns immediately
          stream
        end

        runner.run!

        expect(runner.running?).to be false
      end
    end

    context "when graceful shutdown is triggered" do
      it "fails remaining yielded jobs with preserved retries" do # rubocop:disable RSpec/ExampleLength
        jobs = [
          instance_double(Busybee::Job, key: 1, retries: 3, ready?: true),
          instance_double(Busybee::Job, key: 2, retries: 5, ready?: true)
        ]
        allow(jobs[1]).to receive(:fail!)

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) do |&block|
            block.call(jobs[0])
            runner.stop!
            block.call(jobs[1])
          end
          stream
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

      it "uses the worker's configured backoff during shutdown" do # rubocop:disable RSpec/ExampleLength
        worker_class.backoff 30_000
        job_to_fail = instance_double(Busybee::Job, key: 1, retries: 3, ready?: true)
        allow(job_to_fail).to receive(:fail!)

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) do |&block|
            runner.stop!
            block.call(job_to_fail)
          end
          stream
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

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) do |&block|
            runner.stop!
            block.call(bad_job)
          end
          stream
        end

        runner.run!

        expect(logger).to have_received(:warn).with(/Failed to fail job 99 during shutdown.*grpc gone/)
      end
    end
  end

  describe "#stop!" do
    it "closes the stream to unblock iteration" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each) do
          runner.stop!
        end
        stream
      end

      runner.run!

      # close called by stop! + ensure
      expect(stream).to have_received(:close).at_least(:twice)
    end

    it "is safe to call before stream is opened" do
      expect { runner.stop! }.not_to raise_error
    end
  end

  context "with queue mode (default)" do
    subject(:runner) { described_class.new(queue_worker_class, client: client) }

    let(:queue_worker_class) do
      Class.new(Busybee::Worker) do
        job_type "test_worker"

        def perform
          # no-op
        end
      end
    end

    # Simulate a long-lived gRPC stream: each blocks until close is called.
    # Without this, mock streams that return immediately trigger pump shutdown,
    # racing with the main thread's processing.
    let(:stream_gate) { Concurrent::Event.new }

    before do
      allow(stream).to receive(:close) { stream_gate.set }
    end

    describe "#initialize" do
      it "creates a thread-safe job queue" do
        expect(runner.instance_variable_get(:@job_queue)).to be_a(Queue)
      end

      it "creates an AtomicReference for shutdown error" do
        ref = runner.instance_variable_get(:@shutdown_error)
        expect(ref).to be_a(Concurrent::AtomicReference)
        expect(ref.get).to be_nil
      end
    end

    describe "#run!" do
      it "processes jobs pumped from stream through the queue" do
        streamed_job = instance_double(Busybee::Job, key: 42, retries: 1, ready?: true)

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) do |&block|
            block.call(streamed_job)
            stream_gate.wait # stay open like a real gRPC stream
          end
          stream
        end
        allow(queue_worker_class).to receive(:perform_job) { runner.stop! }

        runner.run!

        expect(queue_worker_class).to have_received(:perform_job).with(streamed_job)
      end

      it "blocks on queue until a job arrives" do
        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) { stream_gate.wait }
          stream
        end
        allow(queue_worker_class).to receive(:perform_job) { runner.stop! }

        # Push a job after a short delay — run! must block until this arrives
        Thread.new do
          sleep 0.05
          runner.instance_variable_get(:@job_queue).push(job)
        end

        runner.run!

        expect(queue_worker_class).to have_received(:perform_job).with(job)
      end

      it "re-raises pump thread stream errors from run!" do
        stream_error = Busybee::GRPC::Error.new("Job stream failed")

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each).and_raise(stream_error)
          stream
        end

        expect { runner.run! }.to raise_error(Busybee::GRPC::Error, "Job stream failed")
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "joins pump thread and drains remaining queue during shutdown" do # rubocop:disable RSpec/ExampleLength
        leftover = instance_double(Busybee::Job, key: 88, retries: 2, ready?: true)
        allow(leftover).to receive(:fail!)

        allow(client).to receive(:open_job_stream) do
          allow(stream).to receive(:each) { stream_gate.wait }
          stream
        end

        # Push a job then stop — the job should be failed during ensure cleanup
        Thread.new do
          sleep 0.05
          runner.instance_variable_get(:@job_queue).push(leftover)
          runner.stop!
        end

        runner.run!

        expect(leftover).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 2,
          backoff: Busybee.default_fail_job_backoff
        )
      end

      context "when stream ends without stop!" do
        it "exits cleanly (does not hang)" do
          allow(client).to receive(:open_job_stream) do
            allow(stream).to receive(:each) # yields nothing, returns immediately
            stream
          end

          thread = Thread.new { runner.run! }
          joined = thread.join(3)

          expect(joined).not_to be_nil, "runner.run! hung — pump thread did not unblock main thread"
          expect(runner.running?).to be false
          expect(runner.stopping?).to be true
        end
      end

      context "when worker raises Busybee::Worker::Shutdown" do
        let(:shutdown_error) { Busybee::Worker::Shutdown.new("shutting down", worker: queue_worker_class) }

        it "stores the error, stops, and re-raises after clean exit" do
          allow(client).to receive(:open_job_stream) do
            allow(stream).to receive(:each) do |&block|
              block.call(job)
              stream_gate.wait
            end
            stream
          end
          allow(queue_worker_class).to receive(:perform_job).and_raise(shutdown_error)

          expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
          expect(runner.stopping?).to be true
          expect(runner.running?).to be false
        end
      end
    end

    describe "#stop!" do
      it "closes the stream and pushes :stop sentinel" do
        runner.instance_variable_set(:@stream, stream)

        runner.stop!

        expect(stream).to have_received(:close)
        expect(runner.instance_variable_get(:@job_queue).pop(true)).to eq(:stop)
      end
    end

    describe "pump delay" do
      context "when queue_throttle is set to a positive value" do
        subject(:runner) { described_class.new(throttled_worker_class, client: client) }

        let(:throttled_worker_class) do
          Class.new(Busybee::Worker) do
            job_type "test_worker"
            streaming queue_throttle: 5
            def perform; end
          end
        end
        let(:stream_gate) { Concurrent::Event.new }

        before do
          allow(stream).to receive(:close) { stream_gate.set }
        end

        it "sleeps between stream reads" do # rubocop:disable RSpec/ExampleLength
          jobs = [
            instance_double(Busybee::Job, key: 1, retries: 1, ready?: true),
            instance_double(Busybee::Job, key: 2, retries: 1, ready?: true)
          ]

          allow(client).to receive(:open_job_stream) do
            allow(stream).to receive(:each) do |&block|
              block.call(jobs[0])
              block.call(jobs[1])
              stream_gate.wait
            end
            stream
          end

          call_count = 0
          allow(throttled_worker_class).to receive(:perform_job) do
            call_count += 1
            runner.stop! if call_count >= 2
          end

          sleep_calls = []
          allow_any_instance_of(described_class).to receive(:sleep) do |_instance, duration| # rubocop:disable RSpec/AnyInstance
            sleep_calls << duration
          end

          runner.run!

          expect(sleep_calls.length).to be >= 1
          expect(sleep_calls).to all(eq(0.005)) # 5ms = 0.005s
        end
      end

      context "when queue_throttle is false (default, no throttling)" do
        # Uses the default queue_worker_class which has no queue_throttle set

        it "does not sleep in the pump thread" do
          allow(client).to receive(:open_job_stream) do
            allow(stream).to receive(:each) do |&block|
              block.call(job)
              stream_gate.wait
            end
            stream
          end
          allow(queue_worker_class).to receive(:perform_job) { runner.stop! }

          allow_any_instance_of(described_class).to receive(:sleep) do |_instance, _duration| # rubocop:disable RSpec/AnyInstance
            raise "sleep should not be called when queue_throttle is false"
          end

          runner.run!

          expect(queue_worker_class).to have_received(:perform_job).with(job)
        end
      end

      context "when queue_throttle is 0 (minimal throttle)" do
        subject(:runner) { described_class.new(zero_delay_worker_class, client: client) }

        let(:zero_delay_worker_class) do
          Class.new(Busybee::Worker) do
            job_type "test_worker"
            streaming queue_throttle: 0
            def perform; end
          end
        end
        let(:stream_gate) { Concurrent::Event.new }

        before do
          allow(stream).to receive(:close) { stream_gate.set }
        end

        it "calls sleep(0) between reads" do
          allow(client).to receive(:open_job_stream) do
            allow(stream).to receive(:each) do |&block|
              block.call(job)
              stream_gate.wait
            end
            stream
          end
          allow(zero_delay_worker_class).to receive(:perform_job) { runner.stop! }

          sleep_calls = []
          allow_any_instance_of(described_class).to receive(:sleep) do |_instance, duration| # rubocop:disable RSpec/AnyInstance
            sleep_calls << duration
          end

          runner.run!

          expect(sleep_calls).to include(0.0)
        end
      end
    end

    describe "#kill!" do
      it "terminates the pump thread" do
        pump = Thread.new { sleep 999 }
        runner.instance_variable_set(:@pump_thread, pump)
        runner.instance_variable_set(:@stream, stream)

        runner.kill!
        pump.join(1)

        expect(pump.alive?).to be false
        expect(runner.stopping?).to be true
      end

      it "flushes the queue, dropping all pending jobs" do
        queue = runner.instance_variable_get(:@job_queue)
        queue.push(instance_double(Busybee::Job, key: 1))
        queue.push(instance_double(Busybee::Job, key: 2))

        runner.kill!

        # Only :stop sentinel should remain
        expect(queue.pop(true)).to eq(:stop)
        expect { queue.pop(true) }.to raise_error(ThreadError) # empty
      end
    end
  end
end
