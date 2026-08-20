# frozen_string_literal: true

require "concurrent"

RSpec.describe Busybee::Runner do
  let(:client) { instance_double(Busybee::Client) }

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "test_worker"

      def perform
        # no-op
      end
    end
  end

  let(:raw_job) do
    # rubocop:disable RSpec/VerifiedDoubles
    double(
      "Busybee::GRPC::ActivatedJob",
      key: 12_345,
      type: "process_order",
      processInstanceKey: 67_890,
      bpmnProcessId: "order-flow",
      processDefinitionKey: 11_111,
      elementId: "Activity_HandleOrder",
      elementInstanceKey: 22_222,
      customHeaders: "{}",
      worker: "test-worker",
      retries: 3,
      deadline: 1_640_000_000_000,
      variables: "{}"
    )
    # rubocop:enable RSpec/VerifiedDoubles
  end

  let(:job) { Busybee::Job.new(raw_job, client: client) }
  let(:runner) { described_class.new(worker_class, client: client) }

  describe "#initialize" do
    it "accepts an explicit client" do
      runner = described_class.new(client: client)
      expect(runner.instance_variable_get(:@client)).to be(client)
    end

    it "creates a default client when none provided" do
      default_client = instance_double(Busybee::Client)
      allow(Busybee::Client).to receive(:new).and_return(default_client)

      runner = described_class.new
      expect(runner.instance_variable_get(:@client)).to be(default_client)
    end
  end

  describe "#run!" do
    it "raises NotImplementedError" do
      runner = described_class.new(client: client)
      expect { runner.run! }.to raise_error(NotImplementedError)
    end
  end

  describe "#stop!" do
    it "sets stopping? to true" do
      runner = described_class.new(client: client)
      expect(runner.stopping?).to be false

      runner.stop!
      expect(runner.stopping?).to be true
    end
  end

  describe "#stopping?" do
    it "returns false initially" do
      runner = described_class.new(client: client)
      expect(runner.stopping?).to be false
    end
  end

  describe "#running?" do
    it "returns false initially" do
      runner = described_class.new(client: client)
      expect(runner.running?).to be false
    end
  end

  describe "#kill!" do
    it "calls stop!" do
      runner = described_class.new(client: client)
      runner.kill!
      expect(runner.stopping?).to be true
    end
  end

  describe ".for" do
    around do |example|
      original = Busybee.instance_variable_get(:@default_worker_mode)
      example.run
      Busybee.default_worker_mode = original
    end

    context "with a single worker class" do
      it "uses runtime_config to resolve runner type" do
        rc = Busybee::RuntimeConfig.new(worker_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "falls back to worker DSL when no runtime_config" do
        worker_class.worker_mode :polling
        runner = described_class.for(worker_class, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "falls back to gem default when no runtime_config and no worker DSL" do
        Busybee.default_worker_mode = :polling
        runner = described_class.for(worker_class, client: client)
        expect(runner).to be_a(Busybee::Runner::Polling)
      end

      it "passes the client to the runner" do
        rc = Busybee::RuntimeConfig.new(worker_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        expect(runner.instance_variable_get(:@client)).to be(client)
      end

      it "creates a default client when none provided" do
        default_client = instance_double(Busybee::Client)
        allow(Busybee::Client).to receive(:new).and_return(default_client)

        rc = Busybee::RuntimeConfig.new(worker_mode: :polling)
        runner = described_class.for(worker_class, runtime_config: rc)
        expect(runner.instance_variable_get(:@client)).to be(default_client)
      end

      it "passes resolved runtime_config to the runner" do
        rc = Busybee::RuntimeConfig.new(worker_mode: :polling, max_jobs: 42)
        runner = described_class.for(worker_class, runtime_config: rc, client: client)
        resolved_config = runner.instance_variable_get(:@runtime_config)
        expect(resolved_config.max_jobs).to eq(42)
        expect(resolved_config.worker_mode).to eq(:polling)
      end

      it "raises ArgumentError for invalid resolved mode" do
        worker_class.instance_variable_get(:@configuration).instance_variable_set(:@worker_mode, :invalid)
        expect { described_class.for(worker_class, client: client) }.
          to raise_error(ArgumentError, /Invalid worker mode.*:invalid/)
      end
    end

    context "with multiple worker classes" do
      let(:other_worker_class) do
        Class.new(Busybee::Worker) do
          job_type "other_worker"

          def perform
            # no-op
          end
        end
      end

      it "returns a Multi runner" do
        rc = Busybee::RuntimeConfig.new(worker_mode: :polling)
        runner = described_class.for(worker_class, other_worker_class, runtime_config: rc, client: client)
        expect(runner).to be_a(Busybee::Runner::Multi)
      end
    end
  end

  describe "#activate_job (private)" do
    let(:worker_class) do
      Class.new do
        def self.name
          "TestWorker"
        end
      end
    end

    after { Busybee::Hooks.reset! }

    it "stamps activated_at on the job (monotonic + utc)" do
      runner.send(:activate_job, job, source: :poll)
      expect(job.activated_at(:monotonic)).to be_a(Float)
      expect(job.activated_at).to be_a(Time)
    end

    it "fires on_job_activated with the Job in :ready status" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :poll)
      expect(received.status).to eq(:ready)
    end

    it "passes the Job with identity keys reachable" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :poll)
      aggregate_failures do
        expect(received).to be(job)
        expect(received.worker_class).to be(worker_class)
        expect(received.type).to eq("process_order")
        expect(received.key).to eq(12_345)
        expect(received.bpmn_process_id).to eq("order-flow")
        expect(received.process_instance_key).to eq(67_890)
        expect(received.element_id).to eq("Activity_HandleOrder")
      end
    end

    it "exposes source on the Job" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :stream)
      expect(received.source).to eq(:stream)
    end

    it "includes source in context_tags" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :stream)
      expect(received.context_tags).to include(source: :stream)
    end

    it "stamps activation timestamps on the Job" do
      Busybee.on_job_activated {} # rubocop:disable Lint/EmptyBlock
      runner.send(:activate_job, job, source: :poll)
      aggregate_failures do
        expect(job.activated_at(:monotonic)).to be_a(Float)
        expect(job.activated_at).to be_a(Time)
      end
    end

    it "defaults buffered? to false (job not buffered)" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :poll)
      expect(received.buffered?).to be(false)
    end

    it "records buffered: true on the Job" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :stream, buffered: true)
      expect(received.buffered?).to be(true)
    end

    it "stamps a Worker::Status onto the Job for job-hook visibility" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :poll)
      expect(received.worker_status).to be_a(Busybee::Worker::Status)
    end

    it "requires source: kwarg" do
      expect { runner.send(:activate_job, job) }.to raise_error(ArgumentError)
    end

    it "swallows hook errors (safe mode)" do
      Busybee.on_job_activated { raise "broken hook" }
      expect { runner.send(:activate_job, job, source: :poll) }.not_to raise_error
    end

    it "still advances the job state when a hook raises" do
      Busybee.on_job_activated { raise "broken hook" }
      runner.send(:activate_job, job, source: :poll)
      expect(job.source).to eq(:poll)
    end

    it "propagates Shutdown errors from hooks" do
      Busybee.on_job_activated { raise Busybee::Worker::Shutdown.new(worker_class: nil) }
      expect do
        runner.send(:activate_job, job, source: :poll)
      end.to raise_error(Busybee::Worker::Shutdown)
    end

    it "respects prefiltering by source" do
      poll_fired = false
      stream_fired = false
      Busybee.on_job_activated(source: :poll) { poll_fired = true }
      Busybee.on_job_activated(source: :stream) { stream_fired = true }
      runner.send(:activate_job, job, source: :poll)
      aggregate_failures do
        expect(poll_fired).to be(true)
        expect(stream_fired).to be(false)
      end
    end

    it "respects prefiltering by worker_class (identity)" do
      fired = false
      Busybee.on_job_activated(worker_class: worker_class) { fired = true }
      runner.send(:activate_job, job, source: :poll)
      expect(fired).to be(true)
    end

    it "respects prefiltering by worker_class (name regexp)" do
      fired = false
      Busybee.on_job_activated(worker_class: /TestWorker/) { fired = true }
      runner.send(:activate_job, job, source: :poll)
      expect(fired).to be(true)
    end
  end

  describe "#activate_job ambient context (private)" do
    let(:worker_class) do
      Class.new do
        def self.name
          "TestWorker"
        end
      end
    end

    after { Busybee::Hooks.reset! }

    it "seeds the job's worker (same object as job.worker_status) so a Call in on_job_activated folds it" do
      captured_call = nil
      Busybee.on_job_activated { captured_call = Busybee::Client::Call.new(:complete_job) }
      runner.send(:activate_job, job, source: :poll)
      expect(captured_call.worker_status).to be(job.worker_status)
    end

    it "does not seed ambient job for on_job_activated (it holds the Job as its carrier)" do
      captured_call = nil
      Busybee.on_job_activated { captured_call = Busybee::Client::Call.new(:complete_job) }
      runner.send(:activate_job, job, source: :poll)
      expect(captured_call.job).to be_nil
    end

    it "restores the previous thread-local carrier after on_job_activated" do
      Busybee.on_job_activated {} # rubocop:disable Lint/EmptyBlock
      runner.send(:activate_job, job, source: :poll)
      expect(Busybee::Client::Call.current_worker_status).to be_nil
    end
  end

  describe "#execute_job (private)" do
    let(:worker_class) do
      Class.new do
        def self.name
          "TestWorker"
        end

        def self.perform_job(_job); end
      end
    end

    before { allow(worker_class).to receive(:perform_job) }
    after { Busybee::Hooks.reset! }

    it "calls @worker_class.perform_job(job)" do
      runner.send(:execute_job, job)
      expect(worker_class).to have_received(:perform_job).with(job)
    end

    it "stamps a fresh Worker::Status onto the Job before executing" do
      captured = nil
      Busybee.on_job_executed { |job| captured = job }
      runner.send(:execute_job, job)
      expect(captured.worker_status).to be_a(Busybee::Worker::Status)
    end

    it "wraps perform_job in the around_job_execution chain" do
      fired = false
      Busybee.around_job_execution do |_job, process|
        fired = true
        process.call
      end
      runner.send(:execute_job, job)
      expect(fired).to be(true)
    end

    it "passes the activated Job to around_job_execution callbacks" do
      runner.send(:activate_job, job, source: :poll)
      received = nil
      Busybee.around_job_execution do |arg, process|
        received = arg
        process.call
      end
      runner.send(:execute_job, job)
      expect(received).to be(job)
    end

    it "passes the Job to around_job_execution callbacks even without prior activate_job" do
      received = nil
      Busybee.around_job_execution do |arg, process|
        received = arg
        process.call
      end
      runner.send(:execute_job, job)
      aggregate_failures do
        expect(received).to be(job)
        expect(received.type).to eq("process_order")
        expect(received.status).to eq(:ready)
        expect(received.source).to be_nil
      end
    end

    it "still calls perform_job when an around hook raises before delegating (safe mode)" do
      Busybee.around_job_execution { |_job, _process| raise "broken hook" }
      runner.send(:execute_job, job)
      expect(worker_class).to have_received(:perform_job).with(job)
    end

    it "does not call perform_job twice when an around hook raises after delegating" do
      Busybee.around_job_execution do |_job, process|
        process.call
        raise "post-process error"
      end
      runner.send(:execute_job, job)
      expect(worker_class).to have_received(:perform_job).with(job).once
    end

    it "swallows hook errors (safe mode)" do
      Busybee.around_job_execution { |_event, _process| raise "broken hook" }
      expect { runner.send(:execute_job, job) }.not_to raise_error
    end

    it "escalates a shutdown_on-declared hook error to Shutdown instead of swallowing it" do
      original = Busybee.shutdown_on_errors
      begin
        Busybee.shutdown_on_errors = [RuntimeError]
        Busybee.around_job_execution { |_job, _process| raise "db gone" }

        expect { runner.send(:execute_job, job) }.to raise_error(Busybee::Worker::Shutdown)
        # Raised pre-yield, so the job is never dispatched — the engine re-delivers
        # it after the activation timeout, same as a hook raising Shutdown directly.
        expect(worker_class).not_to have_received(:perform_job)
      ensure
        Busybee.shutdown_on_errors = original
      end
    end

    it "propagates Shutdown errors from hooks" do
      Busybee.around_job_execution do |_event, _process|
        raise Busybee::Worker::Shutdown.new(worker_class: nil)
      end
      expect { runner.send(:execute_job, job) }.to raise_error(Busybee::Worker::Shutdown)
    end

    it "respects prefiltering by source (via carried event)" do
      fired = []
      Busybee.around_job_execution(source: :poll) do |_e, p|
        fired << :poll
        p.call
      end
      Busybee.around_job_execution(source: :stream) do |_e, p|
        fired << :stream
        p.call
      end
      runner.send(:activate_job, job, source: :poll)
      runner.send(:execute_job, job)
      expect(fired).to eq([:poll])
    end
  end

  describe "hook resolution over the runner's job hooks (private)" do
    let(:worker_class) do
      Class.new do
        def self.name
          "TestWorker"
        end

        def self.perform_job(_job); end
      end
    end

    before do
      allow(worker_class).to receive(:perform_job)
      allow(client).to receive(:complete_job)
    end

    after { Busybee::Hooks.reset! }

    # Resolving from a hook is how a hook short-circuits a job. The claim in
    # each case is that the engine really was told — not merely that nothing
    # raised.
    it "lets on_job_activated resolve the job" do
      Busybee.on_job_activated { |job| job.complete!(skipped: true) }

      runner.send(:activate_job, job, source: :poll)

      aggregate_failures do
        expect(job).to be_completed
        expect(client).to have_received(:complete_job).with(job.key, vars: { "skipped" => true })
      end
    end

    it "lets around_job_execution resolve the job before it yields" do
      Busybee.around_job_execution do |job, process|
        job.complete!(skipped: true)
        process.call
      end

      runner.send(:execute_job, job)

      aggregate_failures do
        expect(job).to be_completed
        expect(client).to have_received(:complete_job).with(job.key, vars: { "skipped" => true })
      end
    end

    it "lets around_job_execution resolve the job after it yields" do
      Busybee.around_job_execution do |job, process|
        process.call
        job.complete!(late: true)
      end

      runner.send(:execute_job, job)

      expect(job).to be_completed
    end

    it "lets on_job_executed resolve the job" do
      Busybee.on_job_executed { |job| job.complete!(late: true) }

      runner.send(:execute_job, job)

      expect(job).to be_completed
    end

    # The chain always descends, one level up: middleware brackets every job
    # that was activated, whether or not there is still work left inside.
    it "still descends into the worker for a job resolved before execution" do
      job.complete!(skipped: true)
      middleware = []
      Busybee.around_job_execution do |_job, process|
        middleware << :before
        process.call
        middleware << :after
      end

      runner.send(:execute_job, job)

      aggregate_failures do
        expect(middleware).to eq(%i[before after])
        expect(worker_class).to have_received(:perform_job).with(job)
      end
    end

    # Deferred resolution is advanced but sanctioned, and nothing on the
    # runner's path interferes with it — including when the thread finishes
    # while the runner is still working through the same job's lifecycle.
    it "lets a thread perform handed the work to resolve whenever it finishes" do
      outcome = nil
      deferred = nil
      allow(worker_class).to receive(:perform_job) do |activated|
        deferred = Thread.new do
          activated.complete!(deferred: true)
          outcome = :resolved
        rescue StandardError => e
          outcome = e
        end
      end
      # Joining from on_job_executed lands the deferred resolution squarely in
      # the middle of the runner's own handling of that job.
      Busybee.on_job_executed { deferred.join }

      runner.send(:execute_job, job)

      expect(outcome).to be(:resolved)
    end
  end

  describe "#execute_job ambient worker context (private)" do
    let(:worker_class) do
      Class.new do
        def self.name
          "TestWorker"
        end

        def self.perform_job(_job); end
      end
    end

    after { Busybee::Hooks.reset! }

    it "seeds the worker (same object as job.worker_status) around perform, so a Call built there folds it" do
      captured_call = nil
      status_during = nil
      allow(worker_class).to receive(:perform_job) do
        status_during = job.worker_status # W_B — before the on_job_executed re-stamp to W_C
        captured_call = Busybee::Client::Call.new(:complete_job)
      end
      runner.send(:execute_job, job)
      expect(captured_call.worker_status).to be(status_during)
    end

    it "seeds around_job_execution middleware's worker as the same object the Job carries" do
      seen_ambient = :unset
      seen_carried = :unset
      Busybee.around_job_execution do |j, process|
        seen_ambient = Busybee::Client::Call.current_worker_status
        seen_carried = j.worker_status
        process.call
      end
      runner.send(:execute_job, job)
      expect(seen_ambient).to be(seen_carried)
    end

    it "does not seed ambient job for around_job_execution middleware (they hold the Job as carrier)" do
      allow(worker_class).to receive(:perform_job)
      seen = :unset
      Busybee.around_job_execution do |_job, process|
        seen = Busybee::Client::Call.current_job
        process.call
      end
      runner.send(:execute_job, job)
      expect(seen).to be_nil
    end

    it "re-stamps a fresh worker for on_job_executed, distinct from the execution-start snapshot" do
      at_perform = nil
      allow(worker_class).to receive(:perform_job) { at_perform = job.worker_status }
      at_executed = nil
      Busybee.on_job_executed { |j| at_executed = j.worker_status }
      runner.send(:execute_job, job)
      aggregate_failures do
        expect(at_perform).to be_a(Busybee::Worker::Status)
        expect(at_executed).to be_a(Busybee::Worker::Status)
        expect(at_executed).not_to be(at_perform)
      end
    end

    it "seeds on_job_executed's ambient worker as the same object job.worker_status carries" do
      captured_call = nil
      Busybee.on_job_executed { captured_call = Busybee::Client::Call.new(:complete_job) }
      runner.send(:execute_job, job)
      expect(captured_call.worker_status).to be(job.worker_status)
    end

    it "restores the previous thread-local carriers after execute_job" do
      allow(worker_class).to receive(:perform_job)
      runner.send(:execute_job, job)
      aggregate_failures do
        expect(Busybee::Client::Call.current_job).to be_nil
        expect(Busybee::Client::Call.current_worker_status).to be_nil
      end
    end
  end

  # End-to-end through the real seed wiring: a Call built inside a real perform,
  # driven by activate_job + execute_job, folds the curated worker + job correlation.
  describe "correlation folded by a perform-issued Call" do
    let(:job) { build_test_job(type: "process_order", retries: 3) }

    def call_from_perform
      captured = nil
      worker_class = stub_const("FoldWiringWorker", Class.new(Busybee::Worker) do
        job_type "process_order"
        strict_outputs false
        complete_job_on_success false
        define_method(:perform) do
          captured = Busybee::Client::Call.new(:complete_job)
          {}
        end
      end)
      rc = Busybee::RuntimeConfig.new(worker_mode: :polling).resolve_for(worker_class)
      runner = described_class.new(worker_class, runtime_config: rc, client: client)
      runner.send(:activate_job, job, source: :poll)
      runner.send(:execute_job, job)
      captured
    end

    it "folds curated worker + job identity into context_tags" do
      expect(call_from_perform.context_tags).to include(
        worker_class: "FoldWiringWorker", job_type: "process_order", worker_mode: :polling,
        bpmn_process_id: job.bpmn_process_id, source: :poll, rpc: :complete_job
      )
    end

    it "keeps lifecycle telemetry (retries, timestamps, gauges, worker_name) out of the tags" do
      tags = call_from_perform.context_tags
      aggregate_failures do
        expect(tags).not_to have_key(:retries)
        expect(tags).not_to have_key(:worker_name)
        expect(tags).not_to have_key(:executed_at)
        expect(tags).not_to have_key(:total_job_count)
      end
    end

    it "adds worker_name and job/instance keys in logging_context, still no job timings" do
      log = call_from_perform.logging_context
      aggregate_failures do
        expect(log).to include(worker_name: Busybee.worker_name, job_key: job.key,
                               process_instance_key: job.process_instance_key)
        expect(log).not_to have_key(:executed_at)
        expect(log).not_to have_key(:deadline)
      end
    end
  end

  describe "execution lifecycle (executed_at + on_job_executed)" do
    let(:worker_class) do
      stub_const("LifecycleWorker", Class.new(Busybee::Worker) do
        job_type "lifecycle_worker"
        strict_outputs false
        define_method(:perform) { { processed: true } }
      end)
    end
    let(:job) { build_test_job(type: worker_class.job_type) }

    after { Busybee::Hooks.reset! }

    describe "executed_at stamping" do
      it "stamps executed_at when execute_job exits successfully" do
        runner.send(:execute_job, job)
        expect(job.executed_at).to be_a(Time)
        expect(job.executed_at).to be >= job.resolved_at
      end

      it "stamps executed_at when perform raises" do
        worker_class = stub_const("ExecutedAtFailWorker", Class.new(Busybee::Worker) do
          job_type "executed_at_fail"
          define_method(:perform) { raise "boom" }
        end)
        runner = described_class.new(worker_class, client: client)
        job = build_test_job(type: worker_class.job_type)
        runner.send(:execute_job, job)
        expect(job.executed_at).to be_a(Time)
      end
    end

    describe "on_job_executed hooks" do
      it "fires on successful completion with executed_at stamped on the Job" do
        captured = nil
        Busybee.on_job_executed { |job| captured = job }
        runner.send(:execute_job, job)
        expect(captured.status).to eq(:complete)
        expect(captured.executed_at).to be_a(Time)
      end

      it "fires on perform failure (autofail path)" do
        worker_class = stub_const("ExecFailWorker", Class.new(Busybee::Worker) do
          job_type "exec_fail"
          define_method(:perform) { raise "boom" }
        end)
        runner = described_class.new(worker_class, client: client)
        job = build_test_job(type: worker_class.job_type)
        captured = nil
        Busybee.on_job_executed { |job| captured = job }
        runner.send(:execute_job, job)
        expect(captured.status).to eq(:failed)
      end

      it "fires on BPMN error" do
        worker_class = stub_const("ExecBpmnWorker", Class.new(Busybee::Worker) do
          job_type "exec_bpmn"
          define_method(:perform) { throw_bpmn_error!(:not_found, "missing") }
        end)
        runner = described_class.new(worker_class, client: client)
        job = build_test_job(type: worker_class.job_type)
        captured = nil
        Busybee.on_job_executed { |job| captured = job }
        runner.send(:execute_job, job)
        expect(captured.status).to eq(:error)
      end

      it "receives the same Job as before_perform (it's the same Job object)" do
        before_perform_arg = nil
        executed_job_arg = nil
        Busybee.before_perform { |j| before_perform_arg = j }
        Busybee.on_job_executed { |j| executed_job_arg = j }
        runner.send(:execute_job, job)
        expect(executed_job_arg).to be(before_perform_arg)
      end

      it "propagates Shutdown errors from the hook" do
        Busybee.on_job_executed { raise Busybee::Worker::Shutdown.new(worker_class: nil) }
        expect { runner.send(:execute_job, job) }.to raise_error(Busybee::Worker::Shutdown)
      end

      it "swallows non-shutdown errors from the hook" do
        Busybee.on_job_executed { raise "broken hook" }
        expect { runner.send(:execute_job, job) }.not_to raise_error
      end
    end
  end

  describe "computed durations end-to-end" do
    let(:worker_class) do
      stub_const("DurationLifecycleWorker", Class.new(Busybee::Worker) do
        job_type "lifecycle_test"
        strict_outputs false
        define_method(:perform) do
          sleep 0.001
          { done: true }
        end
      end)
    end
    let(:job) { build_test_job(type: worker_class.job_type) }

    after { Busybee::Hooks.reset! }

    it "computes all 7 durations with non-nil values across the full lifecycle" do
      captured = nil
      Busybee.on_job_executed { |event| captured = event }

      runner.send(:activate_job, job, source: :poll)
      runner.send(:execute_job, job)

      aggregate_failures do
        expect(captured.buffer_latency_ms).to be_a(Float)
        expect(captured.setup_duration_ms).to be_a(Float)
        expect(captured.perform_duration_ms).to be_a(Float)
        expect(captured.resolution_duration_ms).to be_a(Float)
        expect(captured.execution_duration_ms).to be_a(Float)
        expect(captured.post_resolution_ms).to be_a(Float)
        expect(captured.total_duration_ms).to be_a(Float)
      end
    end

    it "respects auto-complete ordering: perform <= resolution <= execution" do
      captured = nil
      Busybee.on_job_executed { |event| captured = event }

      runner.send(:activate_job, job, source: :poll)
      runner.send(:execute_job, job)

      aggregate_failures do
        expect(captured.perform_duration_ms).to be <= captured.resolution_duration_ms
        expect(captured.resolution_duration_ms).to be <= captured.execution_duration_ms
      end
    end
  end

  describe "job counters (Worker::Status)" do
    def status_for(runner) = runner.send(:worker_status)

    it "counts every processed job in total_job_count" do
      worker_class = stub_const("CountTotalWorker", Class.new(Busybee::Worker) do
        job_type "count_total"
        strict_outputs false
        define_method(:perform) { { ok: true } }
      end)
      runner = described_class.new(worker_class, client: client)

      3.times { runner.send(:execute_job, build_test_job(type: "count_total")) }

      expect(status_for(runner).total_job_count).to eq(3)
    end

    it "counts a :failed outcome (autofail) in failed_job_count" do
      worker_class = stub_const("CountFailWorker", Class.new(Busybee::Worker) do
        job_type "count_fail"
        define_method(:perform) { raise "boom" }
      end)
      runner = described_class.new(worker_class, client: client)

      runner.send(:execute_job, build_test_job(type: "count_fail"))

      aggregate_failures do
        expect(status_for(runner).failed_job_count).to eq(1)
        expect(status_for(runner).total_job_count).to eq(1)
      end
    end

    it "does not count a thrown BPMN error (:error) as failed" do
      worker_class = stub_const("CountBpmnWorker", Class.new(Busybee::Worker) do
        job_type "count_bpmn"
        define_method(:perform) { throw_bpmn_error!(:rejected, "no") }
      end)
      runner = described_class.new(worker_class, client: client)

      runner.send(:execute_job, build_test_job(type: "count_bpmn"))

      aggregate_failures do
        expect(status_for(runner).failed_job_count).to eq(0)
        expect(status_for(runner).total_job_count).to eq(1)
      end
    end
  end
end
