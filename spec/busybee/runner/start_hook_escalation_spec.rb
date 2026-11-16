# frozen_string_literal: true

require "concurrent"

# on_worker_started declaring the worker down, on each kind of worker, with a
# real client. The start is aborted, and the run still passes its closing moments.
RSpec.describe "an escalation from on_worker_started", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:moments) { Concurrent::Array.new }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:shutdown_on) { [] }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])] }
    gateway.on(:stream_activated_jobs) { [] }
    %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown].each do |type|
      Busybee.public_send(type) { |status| moments << [type.to_s.delete_prefix("on_worker_").to_sym, status] }
    end
  end

  def start_hook_worker(mode, shutdown_on: [])
    Class.new(Busybee::Worker) do
      job_type "start_hook_escalation"
      worker_mode mode
      shutdown_on(*shutdown_on) unless shutdown_on.empty?

      def perform = {}
    end
  end

  def fired = moments.map(&:first)
  def status_at(moment) = moments.assoc(moment).last

  shared_examples "an aborted start that still closes" do |error_message|
    it "fires the three closing moments once each, in order, then raises the escalation" do
      raised = run_to_completion

      aggregate_failures do
        expect(raised).to be_a(Busybee::Worker::Shutdown)
        expect(fired).to eq(%i[started stop_requested stopping shutdown])
        expect(moments.drop(1).map { |_, status| status.reason }).to all(eq(:unhealthy))
        expect(status_at(:shutdown).error&.message).to eq(error_message)
        expect(status_at(:shutdown)).to have_attributes(total_job_count: 0, failed_job_count: 0,
                                                        backpressure_count: 0)
      end
    end

    it "fetches nothing and ends no longer running" do
      run_to_completion

      expect(gateway.received(:activate_jobs) + gateway.received(:stream_activated_jobs)).to be_empty
      expect(runner.running?).to be(false)
    end

    it "logs its stop but never that it started" do
      lines = capture_busybee_log(level: Logger::INFO) { run_to_completion }

      expect(lines).to eq(["INFO [busybee] Stopping #{worker_class.name} (unhealthy)",
                           "INFO [busybee] Stopped #{worker_class.name} (unhealthy)"])
    end
  end

  shared_examples "a start hook escalating on any worker" do
    context "when it raises Shutdown" do
      before { Busybee.on_worker_started { raise Busybee::Worker::Shutdown, "replica lagging" } }

      it_behaves_like "an aborted start that still closes", "replica lagging"
    end

    context "when it raises an error the worker shuts down on" do
      let(:shutdown_on) { [stub_const("StartHookFatal", Class.new(StandardError))] }

      before { Busybee.on_worker_started { raise StartHookFatal, "database went away" } }

      it_behaves_like "an aborted start that still closes", "database went away"
    end
  end

  describe "on a polling worker" do
    let(:worker_class) { stub_const("StartPollingWorker", start_hook_worker(:polling, shutdown_on: shutdown_on)) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    it_behaves_like "a start hook escalating on any worker"
  end

  describe "on a buffered streaming worker" do
    let(:worker_class) { stub_const("StartBufferedWorker", start_hook_worker(:streaming, shutdown_on: shutdown_on)) }
    let(:runner) do
      Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    it_behaves_like "a start hook escalating on any worker"
  end

  describe "on an inline streaming worker" do
    let(:worker_class) { stub_const("StartInlineWorker", start_hook_worker(:streaming, shutdown_on: shutdown_on)) }
    let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }
    let(:runner) do
      Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    it_behaves_like "a start hook escalating on any worker"
  end

  describe "on a hybrid worker" do
    let(:worker_class) { stub_const("StartHybridWorker", start_hook_worker(:hybrid, shutdown_on: shutdown_on)) }
    let(:runner) { Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    it_behaves_like "a start hook escalating on any worker"
  end

  describe "on a test worker" do
    let(:worker_class) { stub_const("StartTestWorker", start_hook_worker(:polling)) }

    before { Busybee.on_worker_started { raise Busybee::Worker::Shutdown, "replica lagging" } }

    it "aborts start_test_worker, after the closing moments" do
      expect { start_test_worker(worker_class) }.to raise_error(Busybee::Worker::Shutdown, /replica lagging/)
      expect(fired).to eq(%i[started stop_requested stopping shutdown])
      expect(status_at(:shutdown)).to have_attributes(reason: :unhealthy, total_job_count: 0)
    end

    it "aborts execute_worker before any job runs" do
      performed = false
      worker_class.define_method(:perform) { performed = true }

      expect { execute_worker(worker_class) }.to raise_error(Busybee::Worker::Shutdown)
      expect(fired).to eq(%i[started stop_requested stopping shutdown])
      expect(performed).to be(false)
    end
  end

  describe "in a multi-worker process" do
    let(:worker_class) { stub_const("StartFailingWorker", start_hook_worker(:polling)) }
    let(:sibling_class) { stub_const("StartSiblingWorker", start_hook_worker(:polling)) }
    let(:runner) { Busybee::Runner::Multi.new([worker_class, sibling_class], client: gateway.client) }

    before do
      Busybee.on_worker_started(worker_class: worker_class) { raise Busybee::Worker::Shutdown, "replica lagging" }
    end

    it "closes the failing worker's run before the process raises its escalation" do
      raised = run_to_completion
      failing = moments.select { |_, status| status.worker_class == worker_class }

      expect(raised).to be_a(Busybee::Worker::Shutdown)
      expect(failing.map(&:first)).to eq(%i[started stop_requested stopping shutdown])
      expect(failing.last.last).to have_attributes(reason: :unhealthy, error: raised)
    end
  end

  describe "with an error the process can't recover from" do
    let(:worker_class) { stub_const("StartOutOfMemoryWorker", start_hook_worker(:polling)) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { Busybee.on_worker_started { raise NoMemoryError, "out of memory" } }

    it "raises the fire alarm and closes the run as a crash, then raises the error" do
      raised = run_to_completion

      aggregate_failures do
        expect(raised).to be_a(NoMemoryError)
        expect(Busybee::Runner.exit_immediately?).to be(true)
        expect(fired).to eq(%i[started stop_requested stopping shutdown])
        expect(status_at(:shutdown)).to have_attributes(reason: :crash, error: raised)
        expect(runner.running?).to be(false)
      end
    end
  end
end
