# frozen_string_literal: true

require "concurrent"

# The buffered streaming worker's stop is claimed by whichever thread gets
# there first, the pump or the main thread, and that claim's reason and error
# must stay one fact. Each example widens one window with an injected exit slot
# that pauses inside a write, so the race lands the same way every run.
RSpec.describe "the claim on a streaming worker's stop", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:activating) { Concurrent::Event.new }
  let(:recording) { Concurrent::Event.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  def stream_jobs(*keys)
    gateway.on(:stream_activated_jobs) do
      keys.map { |key| FaultInjectionGateway.activated_job(type: "pump_claim", key: key) }
    end
  end

  # An exit slot that pauses after a write made through method_name.
  def exit_slot_pausing_after(method_name, &pause)
    Class.new(Concurrent::AtomicReference) do
      define_method(method_name) do |*args, &block|
        super(*args, &block).tap { pause.call }
      end
    end.new(nil)
  end

  def run_with_shutdown_status
    raised = nil
    status = shutdown_status_from { raised = run_to_completion }
    [raised, status]
  end

  # Job 1's perform declares the worker down while the pump is inside job 2's
  # activation hook; the hook raises once the main thread is recording its
  # Shutdown, and job 3 waits in the buffer.
  describe "when a pump error arrives while the main thread declares the worker down" do
    let(:worker_class) do
      second_activating = activating
      Class.new(Busybee::Worker) do
        job_type "pump_claim"
        worker_mode :streaming

        define_method(:perform) do
          second_activating.wait(5)
          raise Busybee::Worker::Shutdown, "replica lag too high"
        end
      end
    end

    before do
      paused = recording
      runner.instance_variable_set(:@shutdown_error, exit_slot_pausing_after(:update) { paused.set.then { sleep 0.2 } })
      stream_jobs(1, 3, 2)
      Busybee::Hooks.on_job_activated do |job|
        next unless job.key == 2

        activating.set
        recording.wait(5)
        raise NoMemoryError, "out of room"
      end
    end

    it "ends the run on the Shutdown under the reason it claimed" do
      raised, status = run_with_shutdown_status

      aggregate_failures do
        expect(raised).to be_a(Busybee::Worker::Shutdown)
        expect(status.reason).to eq(:unhealthy)
        expect(status.error).to be_a(Busybee::Worker::Shutdown)
      end
    end

    it "still leaves the buffered job to the engine after the pump's unrecoverable error" do
      run_to_completion

      expect(gateway.received(:fail_job).map(&:jobKey)).not_to include(3)
    end
  end
end
