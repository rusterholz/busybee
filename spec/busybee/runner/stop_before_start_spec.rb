# frozen_string_literal: true

require "concurrent"
require "delegate"

# A stop and a run's start, in either order, with a real client. A stop claimed
# before the run is accepted leaves a worker that never ran: no worker moments,
# one log line. A run accepted first passes all four, the stop's announcement
# on the stopping thread.
RSpec.describe "a stop meeting a worker's start", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:moments) { Concurrent::Array.new }
  let(:worker_class) do
    stub_const("UnstartedWorker", Class.new(Busybee::Worker) do
      job_type "unstarted"
      worker_mode :polling

      def perform = {}
    end)
  end
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])] }
    %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown].each do |type|
      Busybee.public_send(type) do |status|
        moments << [type.to_s.delete_prefix("on_worker_").to_sym, status.worker_class, Thread.current]
      end
    end
  end

  def fired(worker = worker_class) = moments.select { |_, klass, _| klass == worker }.map(&:first)

  describe "a stop claimed before the run is accepted" do
    it "fires no moments, logs that the worker stopped before it started, and never runs" do
      lines = capture_busybee_log(level: Logger::INFO) do
        runner.stop!(reason: :sigterm)
        expect(run_to_completion).to be_nil
      end

      aggregate_failures do
        expect(moments).to be_empty
        expect(lines).to eq(["INFO [busybee] Stopped UnstartedWorker before it started (sigterm)"])
        expect(gateway.received(:activate_jobs)).to be_empty
        expect(runner.running?).to be(false)
      end
    end

    # run! has already looked for a stop and found none when the claim lands.
    it "turns away a start already past run!'s own look for a stop" do
      runner.stop!(reason: :sigterm)

      expect(runner.send(:start!)).to be(false)
      expect(moments).to be_empty
      expect(runner.running?).to be(false)
    end

    it "leaves a test worker stopped before it starts with no moments either" do
      worker = build_test_worker(worker_class)
      lines = capture_busybee_log(level: Logger::INFO) { worker.stop! }

      expect(moments).to be_empty
      expect(lines).to eq(["INFO [busybee] Stopped UnstartedWorker before it started (signal)"])
    end
  end

  describe "a run accepted before the stop's claim" do
    it "announces the stop on the stopping thread at once, even while on_worker_started runs" do
      in_start = Concurrent::Event.new
      release = Concurrent::Event.new
      Busybee.on_worker_started do |_status|
        in_start.set
        release.wait(5)
        moments << [:started_hook_done, worker_class, Thread.current]
      end
      run = Thread.new { run_to_completion }
      in_start.wait(5)
      stopper = Thread.new { runner.stop!(reason: :sigterm) }
      stopper.join(5)
      release.set

      expect(run.value).to be_nil
      expect(fired).to eq(%i[started stop_requested started_hook_done stopping shutdown])
      expect(moments.assoc(:stop_requested).last).to be(stopper)
    end
  end

  # Holds the stopping thread just short of contending for the run's decision,
  # until the run it stopped has torn down on its own thread.
  describe "a stop held after its claim while the accepted run tears down" do
    let(:held) { Concurrent::Event.new }
    let(:release) { Concurrent::Event.new }

    before do
      gate_held = held
      gate_release = release
      decision = runner.instance_variable_get(:@run_decided)
      runner.instance_variable_set(:@run_decided, Class.new(SimpleDelegator) do
        define_method(:make_true) do
          if Thread.current[:hold_decision]
            gate_held.set
            gate_release.wait(5)
          end
          __getobj__.make_true
        end
      end.new(decision))
    end

    def held_stopper
      Thread.new do
        Thread.current[:hold_decision] = true
        runner.stop!(reason: :sigterm)
      end
    end

    it "still reads as the stop of a run that started, never as one before it" do
      started = Concurrent::Event.new
      Busybee.on_worker_started { |_status| started.set }
      lines = capture_busybee_log(level: Logger::INFO) do
        run = Thread.new { run_to_completion }
        started.wait(5)
        stopper = held_stopper
        held.wait(5)
        expect(run.value).to be_nil
        release.set
        stopper.join(5)
      end

      expect(fired).to eq(%i[started stop_requested stopping shutdown])
      expect(lines.grep(/before it started/)).to be_empty
    end
  end

  describe "in a multi-worker process" do
    let(:sibling_class) do
      stub_const("UnstartedSiblingWorker", Class.new(Busybee::Worker) do
        job_type "unstarted_sibling"
        worker_mode :polling

        def perform = {}
      end)
    end
    let(:runner) { Busybee::Runner::Multi.new([worker_class, sibling_class], client: gateway.client) }

    it "gives every worker it stopped before they started no moments, and a line each" do
      lines = capture_busybee_log(level: Logger::INFO) do
        runner.stop!(reason: :sigterm)
        expect(run_to_completion).to be_nil
      end

      expect(moments).to be_empty
      expect(lines).to contain_exactly("INFO [busybee] Stopped UnstartedWorker before it started (sigterm)",
                                       "INFO [busybee] Stopped UnstartedSiblingWorker before it started (sigterm)")
    end

    # The failing worker's cascade usually reaches its sibling before the
    # sibling's thread has started it.
    it "gives a sibling the failure's cascade reaches either no moments or all four" do
      Busybee.on_worker_started(worker_class: worker_class) { raise Busybee::Worker::Shutdown, "replica lagging" }
      lines = capture_busybee_log(level: Logger::INFO) do
        expect(run_to_completion).to be_a(Busybee::Worker::Shutdown)
      end

      aggregate_failures do
        expect(fired).to eq(%i[started stop_requested stopping shutdown])
        expect(fired(sibling_class)).to eq([]).or eq(%i[started stop_requested stopping shutdown])
        if fired(sibling_class).empty?
          expect(lines).to include("INFO [busybee] Stopped UnstartedSiblingWorker before it started (unhealthy)")
        end
      end
    end
  end
end
