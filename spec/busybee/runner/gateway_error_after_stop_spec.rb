# frozen_string_literal: true

require "concurrent"

# The gateway failing a worker's fetch once a stop is under way, through a real
# client: the stop finishes as the graceful stop it was, and the error is
# reported rather than raised.
RSpec.describe "a gateway error after a stop", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  around { |example| isolate_busybee_hooks { example.run } }

  def worker(mode, backpressure_delay: nil)
    delay = backpressure_delay
    Class.new(Busybee::Worker) do
      job_type "gateway_error_after_stop"
      worker_mode mode
      backpressure_delay delay if delay

      def perform = {}
    end
  end

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # The long poll fails once the stop is under way, with the status given.
  def poll_fails_after_stop(status_class)
    stopping = -> { runner }
    waiter = method(:wait_until)
    gateway.on(:activate_jobs) do
      waiter.call { stopping.call.stopping? }
      raise status_class, "the gateway gave up"
    end
  end

  def stop_once_polling
    Thread.new do
      wait_until { gateway.received(:activate_jobs).any? }
      runner.stop!(reason: :sigterm)
    end
  end

  shared_examples "a graceful stop that stands" do
    it "returns from the run, reporting the gateway's error at on_worker_shutdown" do
      raised = :unset
      stopper = stop_once_polling
      status = shutdown_status_from { raised = run_to_completion }
      stopper.join(5)

      aggregate_failures do
        expect(raised).to be_nil
        expect(status.reason).to eq(:sigterm)
        expect(status.error).to have_attributes(class: Busybee::GRPC::Error, grpc_status: :internal)
      end
    end

    it "says so in the log, once" do
      stopper = stop_once_polling
      lines = capture_busybee_log { run_to_completion }
      stopper.join(5)

      expect(lines).to contain_exactly(
        /\AWARN \[busybee\] Error after \(anonymous worker\) began stopping \(sigterm\), finishing the stop \(Busybee::GRPC::Error: .*the gateway gave up.*\)\z/ # rubocop:disable Layout/LineLength
      )
    end

    it "carries the worker's status and the error in JSON" do
      stopper = stop_once_polling
      lines = capture_busybee_log(format: :json) { run_to_completion }
      stopper.join(5)

      expect(lines).to include(a_hash_including("level" => "warn", "reason" => "sigterm",
                                                "job_type" => "gateway_error_after_stop",
                                                "error_class" => "Busybee::GRPC::Error"))
    end
  end

  describe "on a polling worker's long poll" do
    let(:worker_class) { worker(:polling) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { poll_fails_after_stop(GRPC::Internal) }

    it_behaves_like "a graceful stop that stands"
  end

  describe "on a hybrid worker's backlog poll" do
    let(:stream_gate) { Queue.new }
    let(:worker_class) { worker(:hybrid) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) { Enumerator.new { |_| gate.pop } }
      poll_fails_after_stop(GRPC::Internal)
    end

    after { stream_gate.close }

    it_behaves_like "a graceful stop that stands"
  end

  # The stream fails in the moment between a stop claiming its reason and that
  # stop closing the stream, widened by a pause after the claim.
  describe "on an inline streaming worker's stream" do
    let(:worker_class) { worker(:streaming) }
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      pause_after_claiming(0.3)
      stopping = -> { runner }
      waiter = method(:wait_until)
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |_yielder|
          waiter.call { stopping.call.stopping? }
          raise GRPC::Internal, "the gateway gave up"
        end
      end
    end

    def pause_after_claiming(seconds)
      reason = Class.new(Concurrent::AtomicReference) do
        define_method(:compare_and_set) { |*args| super(*args).tap { |won| sleep(seconds) if won } }
      end
      runner.instance_variable_set(:@stop_reason, reason.new(nil))
    end

    # Only once the worker holds its stream: a stop before that ends the run
    # before the stream is read at all.
    def stop_once_polling
      holding = Concurrent::Event.new
      runner.singleton_class.prepend(Module.new do
        define_method(:run_inline) do
          holding.set
          super()
        end
        private :run_inline
      end)
      Thread.new do
        holding.wait(5)
        runner.stop!(reason: :sigterm)
      end
    end

    it_behaves_like "a graceful stop that stands"
  end

  describe "backing off from gateway backpressure" do
    let(:worker_class) { worker(:polling, backpressure_delay: 2000) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    context "when the backpressure arrives after the stop" do
      before { poll_fails_after_stop(GRPC::ResourceExhausted) }

      it "doesn't wait out the delay" do
        stopper = stop_once_polling
        took = elapsed { run_to_completion }
        stopper.join(5)

        expect(took).to be < 1.9 # beats the 2s back-off
      end
    end

    context "when the stop arrives during the back-off" do
      before { gateway.on(:activate_jobs) { raise GRPC::ResourceExhausted, "slow down" } }

      it "stops waiting" do
        stopper = Thread.new do
          wait_until { gateway.received(:activate_jobs).any? }
          sleep 0.2
          runner.stop!(reason: :sigterm)
        end
        took = elapsed { run_to_completion }
        stopper.join(5)

        expect(took).to be < 1.9 # beats the 2s back-off
      end
    end
  end
end
