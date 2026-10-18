# frozen_string_literal: true

require "concurrent"

# Every run passes on_worker_stop_requested before on_worker_stopping, however
# it ends and whichever thread announces the stop, with a real client.
RSpec.describe "the announcement of a worker's stop", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:stream_gate) { Queue.new }
  let(:release) { Concurrent::Event.new }
  let(:moments) { Concurrent::Array.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:shutdown_wait_timeout) { 3000 }

  around { |example| isolate_busybee_hooks { example.run } }
  around { |example| with_shutdown_wait_timeout(shutdown_wait_timeout) { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    record_moments
  end

  after do
    release.set
    stream_gate.close
  end

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "stop_announcement", key: key)

  def record_moments
    recorded = moments
    %i[on_worker_stop_requested on_worker_stopping on_worker_shutdown].each do |type|
      moment = type.to_s.delete_prefix("on_worker_").to_sym
      Busybee.public_send(type) { |status| recorded << [moment, status.reason] }
    end
  end

  # Holds on_worker_stop_requested open, ahead of the recording hook.
  def hold_stop_requested(seconds)
    held = release
    Busybee::Hooks.hooks_for(:on_worker_stop_requested).unshift(
      { callback: ->(_status) { held.wait(seconds) }, filters: {} }
    )
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def streaming_worker(&perform)
    Class.new(Busybee::Worker) do
      job_type "stop_announcement"
      worker_mode :streaming
      define_method(:perform, &perform || proc { {} })
    end
  end

  # The gateway ends the stream, so the stream reader announces the stop on its
  # own thread while the main thread heads for its teardown.
  describe "made by a streaming worker's stream reader" do
    let(:worker_class) { streaming_worker }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:stream_activated_jobs) { [wire_job(1)] }
      hold_stop_requested(0.3)
    end

    it "finishes before the worker starts stopping, which then waits no longer" do
      took = elapsed { run_to_completion }

      expect(moments).to eq([%i[stop_requested gateway_closed], %i[stopping gateway_closed],
                             %i[shutdown gateway_closed]])
      expect(took).to be < 2.5 # well short of the 3s wait it would sit out
    end

    context "when it takes longer than shutdown_wait_timeout" do
      let(:shutdown_wait_timeout) { 100 }

      before { hold_stop_requested(1.5) }

      it "is waited for no longer than that" do
        expect(elapsed { run_to_completion }).to be < 1.4 # beats the 1.5s hold
      end
    end

    context "when the worker is killed while waiting for it" do
      before { hold_stop_requested(2) }

      it "is waited for no longer" do
        killer = Thread.new do
          sleep 0.005 until runner.stopping?
          sleep 0.1
          runner.kill!
        end

        took = elapsed { run_to_completion }
        killer.join

        expect(took).to be < 1.9 # beats the 2s hold
      end
    end
  end

  # The stop is asked for, and announced, on a thread of its own, the way a
  # signal handler does; a kill arrives while the worker waits for it.
  describe "made on another thread when the worker is killed while waiting for it" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "stop_announcement"
        worker_mode :polling

        def perform = {}
      end
    end

    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) do
        sleep 0.05
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
      end
      hold_stop_requested(2)
    end

    it "is waited for no longer" do
      stopper = Thread.new do
        sleep 0.005 until runner.running?
        runner.stop!(reason: :sigterm)
      end
      killer = Thread.new do
        sleep 0.005 until runner.stopping?
        sleep 0.2
        runner.kill!
      end

      took = elapsed { run_to_completion }
      release.set
      [stopper, killer].each { |thread| thread.join(3) }

      expect(took).to be < 1.9 # beats the 2s hold
    end
  end

  # Once job 1's perform has begun, the gateway ends the stream and the stream
  # reader announces that close, slowly; perform then fails unrecoverably, so
  # the process must exit immediately.
  describe "still under way when the process must exit immediately" do
    let(:worker_class) do
      corridor_runner = -> { runner }
      gate = stream_gate
      streaming_worker do
        gate << :performing # the gateway may end the stream only now
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.005 until corridor_runner.call.stopping? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise NoMemoryError, "failed to allocate memory"
      end
    end

    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          gate.pop
        end
      end
      hold_stop_requested(2)
    end

    it "is not waited for" do
      raised = :unset
      took = elapsed { raised = run_to_completion }

      expect([raised, took]).to match([an_instance_of(NoMemoryError), be < 1.9]) # beats the 2s hold
    end
  end

  describe "for a worker crashing with no stop requested" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "stop_announcement"
        worker_mode :polling

        def perform = raise(NoMemoryError, "failed to allocate memory")
      end
    end

    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1)])] } }

    it "is made by the teardown, naming the crash" do
      status = shutdown_status_from { run_to_completion }

      aggregate_failures do
        expect(moments).to eq([%i[stop_requested crash], %i[stopping crash], %i[shutdown crash]])
        expect(status.stop_requested_at).not_to be_nil
      end
    end
  end

  # Job 1 crashes the main thread while the stream is still open; nothing has
  # stopped the worker, and closing the stream wakes the stream reader.
  describe "for a buffered streaming worker crashing on its main thread" do
    let(:worker_class) { streaming_worker { raise NoMemoryError, "failed to allocate memory" } }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          gate.pop
        end
      end
      pause_once_intake_closes
    end

    # Holds the main thread once it closes intake, until something claims the
    # stop, so the stream reader's clean-close claim gets every chance to win.
    def pause_once_intake_closes
      paused = runner
      runner.singleton_class.prepend(Module.new do
        define_method(:cease_intake) do
          super()
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
          sleep 0.002 until paused.stopping? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
        private :cease_intake
      end)
    end

    it "names the crash, announced once, before intake closes" do
      run_to_completion

      expect(moments).to eq([%i[stop_requested crash], %i[stopping crash], %i[shutdown crash]])
    end
  end

  describe "for an inline streaming worker whose stream the gateway ends" do
    let(:worker_class) { streaming_worker }
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { gateway.on(:stream_activated_jobs) { [wire_job(1)] } }

    it "names the gateway's close" do
      expect(run_to_completion).to be_nil
      expect(moments).to eq([%i[stop_requested gateway_closed], %i[stopping gateway_closed],
                             %i[shutdown gateway_closed]])
    end
  end
end
