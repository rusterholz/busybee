# frozen_string_literal: true

require "concurrent"

# The reason a process must exit immediately, as a quiet worker reports it: one
# with nothing to do that ends, unstopped, only once something elsewhere in the
# process has raised the fire alarm. Real client throughout.
RSpec.describe "the reason a process must exit immediately", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:alarm_raised) { Concurrent::Event.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new(**config).resolve_for(quiet_class) }
  let(:config) { {} }
  let(:mode) { :streaming }
  let(:quiet_class) do
    worker_mode = mode
    Class.new(Busybee::Worker) do
      job_type "quiet"
      worker_mode worker_mode

      def perform = {}
    end
  end

  let(:runner) { Busybee::Runner.for(quiet_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    raised = alarm_raised
    gateway.on(:stream_activated_jobs) { Enumerator.new { |_| raised.wait(5) } }
    gateway.on(:activate_jobs) do
      sleep 0.05
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
    end
  end

  after { alarm_raised.set }

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # Runs the quiet worker, raises the alarm(s) the block raises while it runs,
  # then lets its stream end; returns the reason it stopped under.
  def reason_the_quiet_worker_ends_with
    reasons = Concurrent::Array.new
    Busybee.on_worker_shutdown(job_type: "quiet") { |status| reasons << status.reason }
    alarms = Thread.new do
      wait_until { runner.running? }
      yield
      alarm_raised.set
    end
    run_to_completion(seconds: 5)
    alarms.join(5)
    reasons.first
  end

  def kill_a_sibling
    Busybee::Runner::Polling.new(Class.new(Busybee::Worker) { job_type "sibling" },
                                 runtime_config: runtime_config, client: gateway.client).kill!
  end

  # A test worker whose perform runs out of memory: the unrecoverable error passes
  # its execute_job on the way out.
  def crash_a_worker
    crasher = Class.new(Busybee::Worker) do
      job_type "crasher"

      def perform = raise(NoMemoryError, "failed to allocate memory")
    end
    worker = start_test_worker(crasher)
    worker.activate([build_test_job(type: "crasher", client: worker.client)])
  rescue NoMemoryError
    nil
  end

  describe "after a worker is killed" do
    it "is :kill, for a streaming worker reading through a buffer" do
      expect(reason_the_quiet_worker_ends_with { kill_a_sibling }).to eq(:kill)
    end

    context "when the quiet worker streams inline" do
      let(:config) { { buffer: false } }

      it "is :kill" do
        expect(reason_the_quiet_worker_ends_with { kill_a_sibling }).to eq(:kill)
      end
    end

    context "when the quiet worker polls" do
      let(:mode) { :polling }

      it "is :kill" do
        expect(reason_the_quiet_worker_ends_with { kill_a_sibling }).to eq(:kill)
      end
    end
  end

  describe "after a worker dies of an unrecoverable error" do
    it "is :crash" do
      expect(reason_the_quiet_worker_ends_with { crash_a_worker }).to eq(:crash)
    end

    it "stays :crash when a kill follows, the first fire's reason standing" do
      expect(reason_the_quiet_worker_ends_with do
        crash_a_worker
        kill_a_sibling
      end).to eq(:crash)
    end
  end

  # Two quiet polling workers in one process; a kill elsewhere in the process
  # ends them both, and the container takes the fire's reason.
  describe "in a multi-worker process" do
    let(:runner) do
      workers = %w[QuietOne QuietTwo].map do |name|
        stub_const(name, Class.new(Busybee::Worker) do
          job_type name
          worker_mode :polling

          def perform = {}
        end)
      end
      Busybee::Runner::Multi.new(workers, client: gateway.client)
    end

    it "is the container's reason too" do
      killer = Thread.new do
        wait_until { runner.runners.all?(&:running?) }
        kill_a_sibling
      end
      run_to_completion(seconds: 5)
      killer.join(5)

      expect(runner.stop_reason).to eq(:kill)
    end

    # The first worker's long poll fails once the process is told to exit, so
    # that worker's run ends in an ordinary gateway error.
    context "when a worker's run then fails with an ordinary error" do
      before do
        waiter = method(:wait_until)
        gateway.on(:activate_jobs) do |request|
          if request.type == "QuietOne"
            waiter.call { Busybee::Runner.exit_immediately? }
            raise GRPC::Internal, "the gateway gave up"
          end
          sleep 0.3 # the second worker leaves well after the first one's error
          [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
        end
      end

      it "still takes the fire's reason" do
        killer = Thread.new do
          wait_until { runner.runners.all?(&:running?) }
          kill_a_sibling
        end
        raised = run_to_completion(seconds: 5)
        killer.join(5)

        expect([raised.class, runner.stop_reason]).to eq([Busybee::GRPC::Error, :kill])
      end
    end
  end

  # The alarm is process-wide, so Busybee::Testing clears it, reason and all,
  # between examples.
  describe "between examples", order: :defined do
    it "is raised by a kill" do
      kill_a_sibling

      expect(Busybee::Runner.exit_immediately?).to be(true)
    end

    it "starts the next example clear, so that example's own fire names it" do
      expect(reason_the_quiet_worker_ends_with { crash_a_worker }).to eq(:crash)
    end
  end
end
