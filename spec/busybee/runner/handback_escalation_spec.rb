# frozen_string_literal: true

require "concurrent"

# A buffered streaming worker stops with jobs it never started, and the first
# of them handed back has its on_job_not_executed hook declare the worker
# unhealthy. The stop is already under way, so that changes nothing: every job
# still goes back, wherever the stop found it, and the Shutdown is reported.
RSpec.describe "a worker declared down while handing jobs back", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:stream_gate) { Queue.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  after { stream_gate.close }

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "handback_escalation", key: key)

  def worker(&perform)
    Class.new(Busybee::Worker) do
      job_type "handback_escalation"
      worker_mode :streaming
      define_method(:perform, &perform)
    end
  end

  # Registered after the brackets' recorder, so that still sees the handback.
  def declare_down_on_first_handback
    declared = Concurrent::AtomicBoolean.new(false)
    Busybee.on_job_not_executed do |_job|
      raise Busybee::Worker::Shutdown, "replica lag too high" if declared.make_true
    end
  end

  shared_examples "handbacks that carry on" do
    it "hands back every job it never started, and reports the Shutdown" do
      brackets = record_job_brackets
      declare_down_on_first_handback
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion }

      activated = brackets.filter_map { |moment, key| key if moment == :activated }
      handed_back = brackets.filter_map { |moment, key| key if moment == :not_executed }
      aggregate_failures do
        expect(raised).to be_nil
        expect(handed_back).to match_array(activated - started)
        expect(gateway.received(:fail_job).map(&:jobKey)).to match_array(activated - started)
        expect([status&.reason, status&.error]).to match([:sigterm, an_instance_of(Busybee::Worker::Shutdown)])
      end
    end
  end

  # Job 1 is in perform while jobs 2 and 3 buffer; perform then stops the
  # worker, so 2 and 3 go back in the drain.
  context "when the stop finds the jobs in the drain" do
    let(:started) { [1] }
    let(:worker_class) do
      gate = stream_gate
      stopping = -> { runner }
      worker do
        gate << :performing
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.005 until stopping.call.send(:current_buffer_size) == 2 ||
                          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        stopping.call.stop!(reason: :sigterm)
        {}
      end
    end

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          gate.pop
          yielder << wire_job(2)
          yielder << wire_job(3)
          gate.pop
        end
      end
    end

    it_behaves_like "handbacks that carry on"
  end

  # The stop lands as the run loop takes job 1 off the buffer, so job 1 goes
  # back from the loop, and whatever else was buffered in the drain.
  context "when the stop finds the first job in the run loop" do
    let(:started) { [] }
    let(:worker_class) { worker { {} } }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          (1..3).each { |key| yielder << wire_job(key) }
          gate.pop
        end
      end
      stopping = runner
      stop_on_first_take = Class.new(Queue) do
        define_method(:pop) do |*args, **options|
          super(*args, **options).tap { |item| stopping.stop!(reason: :sigterm) unless item == :stop }
        end
      end
      runner.instance_variable_set(:@job_buffer, stop_on_first_take.new)
    end

    it_behaves_like "handbacks that carry on"
  end

  # On a polling worker, job 1's on_job_activated declares the worker down, so
  # the job goes back unworked; that handback's own hook declares it down too.
  context "when the stop is the activation's own escalation" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "handback_escalation"
        worker_mode :polling

        def perform = {}
      end
    end

    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1)])] }
      Busybee.on_job_activated { |_job| raise Busybee::Worker::Shutdown, "from activation" }
      Busybee.on_job_not_executed { |_job| raise Busybee::Worker::Shutdown, "from the handback" }
    end

    it "still ends the run on the activation's Shutdown" do
      raised = run_to_completion

      aggregate_failures do
        expect([raised.class, raised.message]).to eq([Busybee::Worker::Shutdown, "from activation"])
        expect(gateway.received(:fail_job).map(&:jobKey)).to eq([1])
      end
    end
  end
end
