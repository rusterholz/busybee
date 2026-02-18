# frozen_string_literal: true

require "concurrent"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Busybee::Runner::Hybrid do
  subject(:runner) { described_class.new(worker_class, client: client) }

  let(:client) { instance_double(Busybee::Client) }
  let(:job) { instance_double(Busybee::Job, key: 1, retries: 3, ready?: true) }
  let(:stream) { instance_double(Busybee::JobStream) }

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"

      def perform
        # no-op
      end
    end
  end

  # Simulate a long-lived gRPC stream: each blocks until close is called.
  # Without this, mock streams that return immediately trigger pump shutdown,
  # racing with the main thread's drain/queue processing.
  let(:stream_gate) { Concurrent::Event.new }

  before do
    allow(stream).to receive(:close) { stream_gate.set }
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

    it "creates a thread-safe job queue" do
      expect(runner.instance_variable_get(:@job_queue)).to be_a(Queue)
    end

    it "creates an AtomicReference for shutdown error" do
      ref = runner.instance_variable_get(:@shutdown_error)
      expect(ref).to be_a(Concurrent::AtomicReference)
      expect(ref.get).to be_nil
    end
  end

  # Helper: stub client for a Hybrid run! that immediately stops.
  # Yields no backlog jobs (drain exits immediately) and pushes :stop to unblock queue.
  def stub_immediate_stop! # rubocop:disable Metrics/AbcSize
    allow(client).to receive(:open_job_stream).and_return(stream)
    allow(stream).to receive(:each) { stream_gate.wait }
    allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
      runner.stop!
      0
    end
  end

  describe "#run!" do
    it "opens a job stream with streaming options" do
      allow(client).to receive(:open_job_stream) do |type, **opts|
        expect(type).to eq("test_worker")
        expect(opts).to include(:job_timeout)
        allow(stream).to receive(:each)
        stream
      end
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        runner.stop!
        0
      end

      runner.run!
    end

    it "sets running? to true during execution and false after" do
      allow(client).to receive(:open_job_stream) do
        expect(runner.running?).to be true
        allow(stream).to receive(:each)
        stream
      end
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        runner.stop!
        0
      end

      runner.run!

      expect(runner.running?).to be false
    end

    it "sets running? to false even when an error is raised" do
      allow(client).to receive(:open_job_stream).and_raise(RuntimeError, "boom")

      expect { runner.run! }.to raise_error(RuntimeError, "boom")
      expect(runner.running?).to be false
    end

    it "starts a pump thread that pushes stream jobs into the queue" do
      streamed_job = instance_double(Busybee::Job, key: 42, retries: 1, ready?: true)
      allow(streamed_job).to receive(:fail!)
      queue = runner.instance_variable_get(:@job_queue)

      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each) do |&block|
          block.call(streamed_job)
          stream_gate.wait
        end
        stream
      end
      # During drain, check that the pump thread pushed the job into the queue
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        # Give pump thread time to push
        sleep 0.1
        expect(queue.size).to eq(1)
        runner.stop!
        0
      end

      runner.run!
    end

    it "closes the stream in ensure even on normal exit" do
      stub_immediate_stop!

      runner.run!

      # close called by stop! + ensure (idempotent)
      expect(stream).to have_received(:close).at_least(:once)
    end

    it "closes the stream in ensure on error" do
      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each) { stream_gate.wait }
        stream
      end
      allow(client).to receive(:with_each_job).and_raise(RuntimeError, "drain broke")

      expect { runner.run! }.to raise_error(RuntimeError, "drain broke")
      expect(stream).to have_received(:close).at_least(:once)
    end

    it "re-raises pump thread stream errors from run!" do
      stream_error = Busybee::GRPC::Error.new("Job stream failed")

      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each).and_raise(stream_error)
        stream
      end
      # Drain blocks long enough for the pump thread to hit the error and call stop!
      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        sleep 0.1
        0
      end

      expect { runner.run! }.to raise_error(Busybee::GRPC::Error, "Job stream failed")
      expect(runner.stopping?).to be true
      expect(runner.running?).to be false
    end

    it "does not open a stream if already stopping" do
      allow(client).to receive(:open_job_stream)

      runner.stop!
      runner.run!

      expect(client).not_to have_received(:open_job_stream)
      expect(runner.running?).to be false
    end

    context "with drain phase" do
      # Helper: stub stream (no streamed jobs) and set up drain with given block behavior.
      def stub_stream_and_drain!(&drain_block)
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each) { stream_gate.wait }
        allow(client).to receive(:with_each_job, &drain_block)
      end

      it "polls with request_timeout: -1 for immediate return" do
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **opts, &_block|
          expect(opts[:request_timeout]).to eq(-1)
          runner.stop!
          0
        end

        runner.run!
      end

      it "processes polled jobs via worker_class.perform_job" do
        polled_job = instance_double(Busybee::Job, key: 10, retries: 1, ready?: true)

        stub_stream_and_drain! do |_type, **_opts, &block|
          block.call(polled_job)
          runner.stop!
          1
        end
        allow(worker_class).to receive(:perform_job)

        runner.run!

        expect(worker_class).to have_received(:perform_job).with(polled_job)
      end

      it "exits drain when polled < max_jobs (caught-up detection)" do
        poll_count = 0
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          poll_count += 1
          0 # fewer than max_jobs → caught up
        end

        # After drain exits, runner enters blocking queue phase. Stop via background thread.
        Thread.new do
          sleep 0.1
          runner.stop!
        end

        runner.run!

        # Should have polled exactly once (0 < max_jobs → exit drain immediately)
        expect(poll_count).to eq(1)
      end

      it "continues polling when polled == max_jobs (more backlog)" do
        poll_count = 0
        max = Busybee::Defaults::DEFAULT_MAX_JOBS

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          poll_count += 1
          if poll_count == 1
            max.times { block.call(job) }
            max
          else
            runner.stop!
            0
          end
        end

        runner.run!

        expect(poll_count).to eq(2)
      end

      it "drains queued stream jobs after each polled job" do
        polled_job = instance_double(Busybee::Job, key: 10, retries: 1, ready?: true)
        streamed_job = instance_double(Busybee::Job, key: 20, retries: 1, ready?: true)
        process_order = []

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job) do |j|
          process_order << j.key
        end

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          # Simulate a streamed job arriving while polling
          runner.instance_variable_get(:@job_queue).push(streamed_job)
          block.call(polled_job)
          # After polled_job, process_queued_jobs should have drained streamed_job
          runner.stop!
          1
        end

        runner.run!

        # polled_job processed first, then streamed_job (interleaved drain)
        expect(process_order).to eq([10, 20])
      end

      it "sleeps and retries on GRPC::ResourceExhausted during drain" do
        call_count = 0
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          call_count += 1
          raise GRPC::ResourceExhausted, "rate limited" if call_count == 1

          runner.stop!
          0
        end
        allow(runner).to receive(:sleep) # rubocop:disable RSpec/SubjectStub

        runner.run!

        expect(runner).to have_received(:sleep).with(Busybee.runner_backpressure_delay) # rubocop:disable RSpec/SubjectStub
        expect(call_count).to eq(2)
      end
    end

    context "with queue phase" do
      it "processes streamed jobs from the queue after drain completes" do
        streamed_job = instance_double(Busybee::Job, key: 50, retries: 1, ready?: true)
        process_order = []

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job) do |j|
          process_order << j.key
          runner.stop!
        end

        # Drain exits immediately (no backlog)
        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          # Push a job into the queue to simulate a stream arrival
          runner.instance_variable_get(:@job_queue).push(streamed_job)
          0
        end

        runner.run!

        expect(process_order).to eq([50])
      end

      it "blocks until a job arrives on the queue" do
        streamed_job = instance_double(Busybee::Job, key: 77, retries: 1, ready?: true)

        allow(client).to receive_messages(open_job_stream: stream, with_each_job: 0)
        allow(stream).to receive(:each) { stream_gate.wait }
        allow(worker_class).to receive(:perform_job) { runner.stop! }

        # Push a job after a short delay — run! must block until this arrives
        Thread.new do
          sleep 0.05
          runner.instance_variable_get(:@job_queue).push(streamed_job)
        end

        runner.run!

        # If process_queued_jobs didn't block, perform_job would never be called
        # (the queue was empty when it entered blocking mode)
        expect(worker_class).to have_received(:perform_job).with(streamed_job)
      end
    end

    context "with graceful shutdown" do
      it "fails remaining queued jobs during shutdown" do
        leftover = instance_double(Busybee::Job, key: 88, retries: 2, ready?: true)
        allow(leftover).to receive(:fail!)

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          # Push a job, then stop — the job should be failed during shutdown
          runner.instance_variable_get(:@job_queue).push(leftover)
          runner.stop!
          0
        end

        runner.run!

        expect(leftover).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 2,
          backoff: Busybee.runner_shutdown_backoff
        )
      end

      it "uses the greater of shutdown_backoff and worker backoff" do
        worker_class.backoff 30_000 # 30s > default shutdown_backoff of 10s
        leftover = instance_double(Busybee::Job, key: 1, retries: 3, ready?: true)
        allow(leftover).to receive(:fail!)

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_queue).push(leftover)
          runner.stop!
          0
        end

        runner.run!

        expect(leftover).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 3,
          backoff: 30_000
        )
      end

      it "fails polled jobs yielded after stop! during drain" do
        jobs = [
          instance_double(Busybee::Job, key: 1, retries: 3, ready?: true),
          instance_double(Busybee::Job, key: 2, retries: 5, ready?: true)
        ]
        allow(jobs[1]).to receive(:fail!)

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          block.call(jobs[0])
          runner.stop!
          block.call(jobs[1])
          2
        end

        runner.run!

        expect(worker_class).to have_received(:perform_job).with(jobs[0]).once
        expect(worker_class).not_to have_received(:perform_job).with(jobs[1])
        expect(jobs[1]).to have_received(:fail!).with(
          "Worker shutting down",
          retries: 5,
          backoff: Busybee.runner_shutdown_backoff
        )
      end

      it "logs a warning when failing a shutdown job raises an error" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        bad_job = instance_double(Busybee::Job, key: 99, retries: 1, ready?: true)
        allow(bad_job).to receive(:fail!).and_raise(StandardError, "grpc gone")

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_queue).push(bad_job)
          runner.stop!
          0
        end

        runner.run!

        expect(logger).to have_received(:warn).with(/Failed to fail job 99 during shutdown.*grpc gone/)
      end
    end

    context "when worker raises Busybee::Worker::Shutdown" do
      let(:shutdown_error) { Busybee::Worker::Shutdown.new("shutting down", worker: worker_class) }

      it "stores the error, stops, and re-raises after clean exit during drain" do
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          block.call(job)
          1
        end

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "stores the error, stops, and re-raises after clean exit during queue phase" do
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        # Drain exits immediately, Shutdown happens in queue phase
        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_queue).push(job)
          0
        end

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "uses first-error-wins when shutdown happens in both threads" do
        stream_error = Busybee::GRPC::Error.new("stream broke")
        allow(job).to receive(:fail!)

        allow(client).to receive(:open_job_stream) do
          # Pump thread will hit this error
          allow(stream).to receive(:each).and_raise(stream_error)
          stream
        end

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          sleep 0.1 # let pump thread store its error and call stop! first
          block.call(job) # stopping? is true → handle_shutdown_job
          1
        end

        # First error wins — stream_error was stored first
        expect { runner.run! }.to raise_error(Busybee::GRPC::Error, "stream broke")
      end
    end
  end

  describe "#stop!" do
    it "closes the stream and pushes :stop sentinel" do
      # Set up a stream on the runner to verify close
      runner.instance_variable_set(:@stream, stream)

      runner.stop!

      expect(stream).to have_received(:close)
      expect(runner.instance_variable_get(:@job_queue).pop(true)).to eq(:stop)
    end

    it "is safe to call before run!" do
      expect { runner.stop! }.not_to raise_error
    end
  end
end
# rubocop:enable RSpec/ExampleLength
