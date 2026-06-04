# frozen_string_literal: true

RSpec.describe Busybee::Runner do
  let(:client) { instance_double(Busybee::Client) }

  let(:worker_class) do
    Class.new do
      def self.name
        "TestWorker"
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

  describe "#activate_job (private)" do
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

    it "defaults buffer_size to nil (signals job-not-buffered)" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :poll)
      expect(received.buffer_size).to be_nil
    end

    it "captures the given buffer_size on the Job" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :stream, buffer_size: 7)
      expect(received.buffer_size).to eq(7)
    end

    it "allows buffer_size of 0 (queue was empty when job arrived)" do
      received = nil
      Busybee.on_job_activated { |job| received = job }
      runner.send(:activate_job, job, source: :stream, buffer_size: 0)
      expect(received.buffer_size).to eq(0)
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
      Busybee.on_job_activated { raise Busybee::Worker::Shutdown.new(worker: nil) }
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

    it "propagates Shutdown errors from hooks" do
      Busybee.around_job_execution do |_event, _process|
        raise Busybee::Worker::Shutdown.new(worker: nil)
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

      it "receives the same Job as before_job (it's the same Job object)" do
        before_job_arg = nil
        executed_job_arg = nil
        Busybee.before_job { |j| before_job_arg = j }
        Busybee.on_job_executed { |j| executed_job_arg = j }
        runner.send(:execute_job, job)
        expect(executed_job_arg).to be(before_job_arg)
      end

      it "propagates Shutdown errors from the hook" do
        Busybee.on_job_executed { raise Busybee::Worker::Shutdown.new(worker: nil) }
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
end
