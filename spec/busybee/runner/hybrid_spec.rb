# frozen_string_literal: true

require "concurrent"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Busybee::Runner::Hybrid do
  subject(:runner) { described_class.new(worker_class, runtime_config: runtime_config, client: client) }

  let(:client) { instance_double(Busybee::Client) }
  let(:job) { build_test_job(key: 1, retries: 3) }
  let(:stream) { instance_double(Busybee::JobStream) }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

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
  # racing with the main thread's drain/buffer processing.
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

    it "creates a thread-safe job buffer" do
      expect(runner.instance_variable_get(:@job_buffer)).to be_a(Queue)
    end

    it "creates an AtomicReference for shutdown error" do
      ref = runner.instance_variable_get(:@shutdown_error)
      expect(ref).to be_a(Concurrent::AtomicReference)
      expect(ref.get).to be_nil
    end
  end

  # Helper: stub client for a Hybrid run! that immediately stops.
  # Yields no backlog jobs (drain exits immediately) and pushes :stop to unblock buffer.
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

    it "starts a pump thread that pushes stream jobs into the buffer" do
      streamed_job = build_test_job(key: 42, retries: 1)
      allow(client).to receive(:fail_job) # the drain hands it back; this example is about the pump
      queue = runner.instance_variable_get(:@job_buffer)

      allow(client).to receive(:open_job_stream) do
        allow(stream).to receive(:each) do |&block|
          block.call(streamed_job)
          stream_gate.wait
        end
        stream
      end
      # During drain, check that the pump thread pushed the job into the buffer
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
        polled_job = build_test_job(key: 10, retries: 1)

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

        # After drain exits, runner enters blocking buffer phase. Stop via background thread.
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
        polled_job = build_test_job(key: 10, retries: 1)
        streamed_job = build_test_job(key: 20, retries: 1)
        process_order = []

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job) do |j|
          process_order << j.key
        end

        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          # Simulate a streamed job arriving while polling
          runner.instance_variable_get(:@job_buffer).push(streamed_job)
          block.call(polled_job)
          # After polled_job, process_buffered_jobs should have drained streamed_job
          runner.stop!
          1
        end

        runner.run!

        # polled_job processed first, then streamed_job (interleaved drain)
        expect(process_order).to eq([10, 20])
      end

      # Doubled client, so the wrapped arrival is a premise — the real drain
      # corridor is pinned in backpressure_corridor_spec.rb.
      it "backs off on a wrapped ResourceExhausted during drain (gateway backpressure)" do
        call_count = 0
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          call_count += 1
          raise Busybee::GRPC::Error.wrap(GRPC::ResourceExhausted.new("rate limited")) if call_count == 1

          runner.stop!
          0
        end
        allow(runner).to receive(:sleep) # rubocop:disable RSpec/SubjectStub

        runner.run!

        # 2_000 ms configured, and sleep takes seconds. See polling_spec for why
        # asserting the configured value instead is what hid the missing conversion.
        expect(runner).to have_received(:sleep).with(2.0) # rubocop:disable RSpec/SubjectStub
        expect(call_count).to eq(2)
      end
    end

    context "with buffer phase" do
      it "processes streamed jobs from the buffer after drain completes" do
        streamed_job = build_test_job(key: 50, retries: 1)
        process_order = []

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job) do |j|
          process_order << j.key
          runner.stop!
        end

        # Drain exits immediately (no backlog)
        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          # Push a job into the buffer to simulate a stream arrival
          runner.instance_variable_get(:@job_buffer).push(streamed_job)
          0
        end

        runner.run!

        expect(process_order).to eq([50])
      end

      it "blocks until a job arrives in the buffer" do
        streamed_job = build_test_job(key: 77, retries: 1)

        allow(client).to receive_messages(open_job_stream: stream, with_each_job: 0)
        allow(stream).to receive(:each) { stream_gate.wait }
        allow(worker_class).to receive(:perform_job) { runner.stop! }

        # Push a job after a short delay — run! must block until this arrives
        Thread.new do
          sleep 0.05
          runner.instance_variable_get(:@job_buffer).push(streamed_job)
        end

        runner.run!

        # If process_buffered_jobs didn't block, perform_job would never be called
        # (the buffer was empty when it entered blocking mode)
        expect(worker_class).to have_received(:perform_job).with(streamed_job)
      end
    end

    context "with graceful shutdown" do
      it "hands remaining queued jobs back during shutdown, unworked" do
        leftover = build_test_job(key: 88, retries: 2)
        allow(client).to receive(:fail_job)

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          # Push a job, then stop — the job should be failed during shutdown
          runner.instance_variable_get(:@job_buffer).push(leftover)
          runner.stop!
          0
        end

        runner.run!

        aggregate_failures do
          expect(client).to have_received(:fail_job).with(
            88, "Worker shutting down", retries: 2, backoff: Busybee.default_fail_job_backoff
          )
          expect(leftover.status).to eq(:ready)
        end
      end

      it "uses the worker's configured backoff during shutdown" do
        worker_class.fail_job_backoff 30_000
        leftover = build_test_job(key: 1, retries: 3)
        allow(client).to receive(:fail_job)

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_buffer).push(leftover)
          runner.stop!
          0
        end

        runner.run!

        expect(client).to have_received(:fail_job).with(
          1, "Worker shutting down", retries: 3, backoff: 30_000
        )
      end

      it "hands polled jobs yielded after stop! back during drain" do
        jobs = [
          build_test_job(key: 1, retries: 3),
          build_test_job(key: 2, retries: 5)
        ]
        allow(client).to receive(:fail_job)

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

        aggregate_failures do
          expect(worker_class).to have_received(:perform_job).with(jobs[0]).once
          expect(worker_class).not_to have_received(:perform_job).with(jobs[1])
          expect(client).to have_received(:fail_job).with(
            2, "Worker shutting down", retries: 5, backoff: Busybee.default_fail_job_backoff
          )
          expect(jobs[1].status).to eq(:ready)
        end
      end

      it "logs a warning when handing a shutdown job back raises an error" do
        logger = instance_double(Logger, warn: nil)
        allow(Busybee).to receive(:logger).and_return(logger)

        bad_job = build_test_job(key: 99, retries: 1)
        allow(client).to receive(:fail_job).and_raise(StandardError, "grpc gone")

        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)

        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_buffer).push(bad_job)
          runner.stop!
          0
        end

        runner.run!

        expect(logger).to have_received(:warn).with(/Failed to hand job 99 back during shutdown.*grpc gone/)
      end
    end

    context "when worker raises Busybee::Worker::Shutdown" do
      let(:shutdown_error) { Busybee::Worker::Shutdown.new("shutting down", worker_class: worker_class) }

      around { |example| isolate_busybee_hooks { example.run } }

      it "tags the stop :unhealthy — the worker declared itself down" do
        captured = nil
        Busybee.on_worker_shutdown { |worker| captured = worker }
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)
        allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
          block.call(job)
          1
        end

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(captured.reason).to eq(:unhealthy)
      end

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

      it "stores the error, stops, and re-raises after clean exit during buffer phase" do
        allow(client).to receive(:open_job_stream).and_return(stream)
        allow(stream).to receive(:each)
        allow(worker_class).to receive(:perform_job).and_raise(shutdown_error)

        # Drain exits immediately, Shutdown happens in buffer phase
        allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
          runner.instance_variable_get(:@job_buffer).push(job)
          0
        end

        expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)
        expect(runner.stopping?).to be true
        expect(runner.running?).to be false
      end

      it "uses first-error-wins when shutdown happens in both threads" do
        stream_error = Busybee::GRPC::Error.new("stream broke")
        allow(client).to receive(:fail_job) # incidental to the claim, which is which error wins

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
      expect(runner.instance_variable_get(:@job_buffer).pop(true)).to eq(:stop)
    end

    it "is safe to call before run!" do
      expect { runner.stop! }.not_to raise_error
    end
  end

  describe "#kill!" do
    around { |example| isolate_busybee_hooks { example.run } }

    # A kill discards rather than hands back, and it runs no job hooks at all —
    # the container is stuck, and adopter code is a poor bet there.
    it "flushes queued stream jobs without handing them back or firing job hooks" do
      queued_job = build_test_job(key: 99, retries: 3)
      allow(client).to receive(:fail_job)
      allow(worker_class).to receive(:perform_job)
      fired = []
      Busybee.on_job_not_executed { fired << :not_executed }

      allow(client).to receive(:open_job_stream).and_return(stream)
      allow(stream).to receive(:each) { stream_gate.wait }

      allow(client).to receive(:with_each_job) do |_type, **_opts, &_block|
        runner.instance_variable_get(:@job_buffer).push(queued_job)
        runner.kill!
        0
      end

      runner.run!

      aggregate_failures do
        expect(worker_class).not_to have_received(:perform_job).with(queued_job)
        expect(client).not_to have_received(:fail_job)
        expect(fired).to be_empty
      end
    end

    it "still completes the in-flight polled job but hands subsequently-yielded ones back" do
      inflight = build_test_job(key: 1, retries: 3)
      yielded_after = build_test_job(key: 2, retries: 5)
      allow(client).to receive(:fail_job)

      allow(client).to receive(:open_job_stream).and_return(stream)
      allow(stream).to receive(:each) { stream_gate.wait }
      allow(worker_class).to receive(:perform_job) { runner.kill! }

      allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
        block.call(inflight)       # perform_job calls kill! during this
        block.call(yielded_after)  # yielded after kill! — handled as shutdown
        2
      end

      runner.run!

      aggregate_failures do
        expect(worker_class).to have_received(:perform_job).with(inflight)
        expect(worker_class).not_to have_received(:perform_job).with(yielded_after)
        expect(client).to have_received(:fail_job).with(2, "Worker shutting down", retries: 5, backoff: anything)
      end
    end
  end

  describe "on_job_activated wiring (drain phase)" do
    around { |example| isolate_busybee_hooks { example.run } }

    it "fires on_job_activated with source: :poll during backlog drain" do
      polled_job = build_test_job(key: 10, retries: 1)
      captured = nil
      Busybee.on_job_activated { |job| captured = job }

      allow(client).to receive(:open_job_stream).and_return(stream)
      allow(stream).to receive(:each) { stream_gate.wait }
      allow(client).to receive(:with_each_job) do |_type, **_opts, &block|
        block.call(polled_job)
        runner.stop!
        1
      end
      allow(worker_class).to receive(:perform_job)

      runner.run!

      expect(captured.source).to eq(:poll)
      expect(captured.buffered?).to be(false) # drain-phase jobs arrive via poll, unbuffered
    end
  end
end
# rubocop:enable RSpec/ExampleLength
