# frozen_string_literal: true

require "concurrent"

# An error ending the streaming pump while a graceful stop is already under
# way: the stop arrives while the pump is inside a slow on_job_activated, which
# raises only once the teardown has begun. Job 1 is in perform and stops the
# worker, job 3 waits in the buffer, and job 2's activation hook is the slow one.
RSpec.describe "an error ending the streaming pump after the stop", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:activating) { Queue.new }
  let(:teardown_begun) { Concurrent::Event.new }
  let(:worker_class) do
    corridor_runner = -> { runner }
    second_activating = activating
    Class.new(Busybee::Worker) do
      job_type "late_pump_error"
      worker_mode :streaming

      define_method(:perform) do
        second_activating.pop(timeout: 5)
        corridor_runner.call.stop!(reason: :signal)
        {}
      end
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
    gateway.on(:stream_activated_jobs) do
      [1, 3, 2].map { |key| FaultInjectionGateway.activated_job(type: "late_pump_error", key: key) }
    end
    Busybee::Hooks.on_worker_stopping { teardown_begun.set }
  end

  def raise_late_from_activation(error)
    Busybee::Hooks.on_job_activated(&late_activation_hook(error))
  end

  def late_activation_hook(error)
    lambda do |job|
      next unless job.key == 2

      activating << :activating
      teardown_begun.wait(5)
      raise error
    end
  end

  def run_with_shutdown_status
    raised = nil
    status = shutdown_status_from { raised = run_to_completion }
    [raised, status]
  end

  shared_examples "a graceful stop that stands" do
    it "returns from the run without raising it, reporting it at on_worker_shutdown" do
      raised, status = run_with_shutdown_status

      aggregate_failures do
        expect(raised).to be_nil
        expect(status.error).to be_a(error_class)
        expect(status.reason).to eq(:signal)
        expect(runner.running?).to be(false)
      end
    end
  end

  [NoMemoryError, SystemStackError].each do |unrecoverable|
    context "when it is a #{unrecoverable}" do
      let(:error_class) { unrecoverable }

      before { raise_late_from_activation(unrecoverable.new("out of room")) }

      it_behaves_like "a graceful stop that stands"

      it "hands nothing back, leaving the activated jobs for the engine to reclaim" do
        run_to_completion

        expect(gateway.received(:fail_job)).to be_empty
      end
    end
  end

  context "when it is a Shutdown" do
    let(:error_class) { Busybee::Worker::Shutdown }

    before { raise_late_from_activation(Busybee::Worker::Shutdown.new("replica lag too high")) }

    it_behaves_like "a graceful stop that stands"

    it "hands back both the job whose hook raised it and the buffered one" do
      run_to_completion

      expect(gateway.received(:fail_job).map(&:jobKey)).to contain_exactly(2, 3)
    end
  end

  context "when it is a shutdown_on match" do
    let(:error_class) { ReplicaLagging }

    before do
      stub_const("ReplicaLagging", Class.new(StandardError))
      Busybee.shutdown_on_errors = [ReplicaLagging]
      raise_late_from_activation(ReplicaLagging.new("replica lag too high"))
    end

    after { Busybee.shutdown_on_errors = nil }

    it_behaves_like "a graceful stop that stands"
  end

  # Here the error is on record before job 1's perform returns, so before the
  # main thread looks for an exit error at all.
  context "when it lands before the main thread reads" do
    let(:error_class) { NoMemoryError }
    let(:stopped) { Concurrent::Event.new }
    let(:worker_class) do
      corridor_runner = -> { runner }
      second_activating = activating
      stop_made = stopped
      Class.new(Busybee::Worker) do
        job_type "late_pump_error"
        worker_mode :streaming

        define_method(:perform) do
          second_activating.pop(timeout: 5)
          corridor_runner.call.stop!(reason: :signal)
          stop_made.set
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep 0.005 until corridor_runner.call.send(:late_error) ||
                            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          {}
        end
      end
    end

    before do
      Busybee::Hooks.on_job_activated do |job|
        next unless job.key == 2

        activating << :activating
        stopped.wait(5)
        raise NoMemoryError, "out of room"
      end
    end

    it_behaves_like "a graceful stop that stands"

    it "hands nothing back, leaving the activated jobs for the engine to reclaim" do
      run_to_completion

      expect(gateway.received(:fail_job)).to be_empty
    end
  end
end
