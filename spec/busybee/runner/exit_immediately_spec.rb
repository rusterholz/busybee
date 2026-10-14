# frozen_string_literal: true

require "concurrent"

# Once anything in the process meets an error it cannot recover from, every
# runner drops its work and leaves: no handbacks, no drains, no job hooks.
RSpec.describe "a process that must exit immediately", :gateway do # rubocop:disable RSpec/DescribeClass
  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  def wire_job(key, type = "exit_immediately") = FaultInjectionGateway.activated_job(type: type, key: key)

  def poll_for(type, *keys)
    gateway.on(:activate_jobs) do |request|
      jobs = request.type == type ? keys.map { |key| wire_job(key, type) } : []
      sleep 0.05 if jobs.empty?
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: jobs)]
    end
  end

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # The flag is process-wide, so Busybee::Testing clears it between examples.
  describe "between examples", order: :defined do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "exit_immediately"
        worker_mode :polling

        def perform = raise(NoMemoryError, "failed to allocate memory")
      end
    end

    let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    it "is raised by an unrecoverable error" do
      poll_for("exit_immediately", 1)
      run_to_completion

      expect(Busybee::Runner.exit_immediately?).to be(true)
    end

    it "is lowered again for the next example" do
      expect(Busybee::Runner.exit_immediately?).to be(false)
    end
  end

  # perform stops the worker, then fails in a way it cannot recover from.
  describe "an unrecoverable error on the main thread during a stop" do
    let(:worker_class) do
      mode = worker_mode
      corridor_runner = -> { runner }
      Class.new(Busybee::Worker) do
        job_type "exit_immediately"
        worker_mode mode

        define_method(:perform) do
          corridor_runner.call.stop!(reason: :sigterm)
          raise NoMemoryError, "failed to allocate memory"
        end
      end
    end

    let(:runner) { runner_class.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
    let(:stream_gate) { Queue.new }

    after { stream_gate.close }

    def deliver_by_stream
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          yielder << wire_job(1)
          yielder << wire_job(2)
          gate.pop
        end
      end
    end

    shared_examples "an unrecoverable error that still ends the run" do
      it "raises it, sends the engine nothing back, and tells the process to exit immediately" do
        raised = run_to_completion

        aggregate_failures do
          expect(raised).to be_a(NoMemoryError)
          expect(gateway.received(:fail_job)).to be_empty
          expect(Busybee::Runner.exit_immediately?).to be(true)
        end
      end
    end

    describe "on a polling worker" do
      let(:worker_mode) { :polling }
      let(:runner_class) { Busybee::Runner::Polling }
      let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

      before { poll_for("exit_immediately", 1, 2) }

      it_behaves_like "an unrecoverable error that still ends the run"
    end

    describe "on a buffered streaming worker" do
      let(:worker_mode) { :streaming }
      let(:runner_class) { Busybee::Runner::Streaming }
      let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

      before { deliver_by_stream }

      it_behaves_like "an unrecoverable error that still ends the run"
    end

    describe "on an inline streaming worker" do
      let(:worker_mode) { :streaming }
      let(:runner_class) { Busybee::Runner::Streaming }
      let(:runtime_config) { Busybee::RuntimeConfig.new(buffer: false).resolve_for(worker_class) }

      before { deliver_by_stream }

      it_behaves_like "an unrecoverable error that still ends the run"
    end

    describe "on a hybrid worker draining its backlog" do
      let(:worker_mode) { :hybrid }
      let(:runner_class) { Busybee::Runner::Hybrid }
      let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

      before do
        gate = stream_gate
        gateway.on(:stream_activated_jobs) { Enumerator.new { |_| gate.pop } }
        poll_for("exit_immediately", 1, 2)
      end

      it_behaves_like "an unrecoverable error that still ends the run"
    end
  end

  # The graceful stop is already under way when the kill lands, with the
  # batch's second job still in hand.
  describe "a kill" do
    let(:worker_class) do
      corridor_runner = -> { runner }
      Class.new(Busybee::Worker) do
        job_type "exit_immediately"
        worker_mode :polling

        define_method(:perform) do
          corridor_runner.call.stop!(reason: :sigterm)
          corridor_runner.call.kill!
          {}
        end
      end
    end

    let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before { poll_for("exit_immediately", 1, 2) }

    it "runs no job hooks and hands nothing back" do
      brackets = record_job_brackets
      run_to_completion

      aggregate_failures do
        expect(brackets).to eq([[:activated, 1]])
        expect(gateway.received(:fail_job)).to be_empty
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end

  # Three jobs wait in the buffer when the stop lands; the first one handed
  # back trips an unrecoverable error in its on_job_not_executed hook.
  describe "an unrecoverable error during the drain" do
    let(:worker_class) do
      corridor_runner = -> { runner }
      Class.new(Busybee::Worker) do
        job_type "exit_immediately"
        worker_mode :streaming

        define_method(:perform) do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep 0.005 until corridor_runner.call.send(:current_buffer_size) == 3 ||
                            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          corridor_runner.call.stop!(reason: :sigterm)
          {}
        end
      end
    end

    let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Streaming.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
    let(:stream_gate) { Queue.new }

    before do
      gate = stream_gate
      gateway.on(:stream_activated_jobs) do
        Enumerator.new do |yielder|
          (1..4).each { |key| yielder << wire_job(key) }
          gate.pop
        end
      end
      Busybee::Hooks.on_job_not_executed { |_job| raise NoMemoryError, "failed to allocate memory" }
    end

    after { stream_gate.close }

    it "abandons the rest of the drain and finishes the stop it was making" do
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion }

      aggregate_failures do
        expect(raised).to be_nil
        expect(gateway.received(:fail_job).map(&:jobKey)).to eq([2])
        expect([status.reason, status.error]).to match([:sigterm, an_instance_of(NoMemoryError)])
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end

  # Job 1's perform stops the worker, so the batch's job 2, already in hand,
  # goes back, and its on_job_not_executed hook fails unrecoverably.
  describe "an unrecoverable error handing back the job in hand" do
    let(:worker_class) do
      corridor_runner = -> { runner }
      Class.new(Busybee::Worker) do
        job_type "exit_immediately"
        worker_mode :polling

        define_method(:perform) do
          corridor_runner.call.stop!(reason: :sigterm)
          {}
        end
      end
    end

    let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      poll_for("exit_immediately", 1, 2)
      Busybee::Hooks.on_job_not_executed { |_job| raise NoMemoryError, "failed to allocate memory" }
    end

    it "finishes the stop it was making, and says to exit immediately" do
      raised = :unset
      status = shutdown_status_from { raised = run_to_completion }

      aggregate_failures do
        expect(raised).to be_nil
        expect([status&.reason, status&.error]).to match([:sigterm, an_instance_of(NoMemoryError)])
        expect(runner.running?).to be(false)
        expect(Busybee::Runner.exit_immediately?).to be(true)
      end
    end
  end

  describe "in a multi-worker process" do
    let(:stream_gate) { Queue.new }
    let(:alpha_class) { stub_const("AlphaWorker", worker("alpha", alpha_mode, &alpha_perform)) }
    let(:beta_class) { stub_const("BetaWorker", worker("beta", :polling, &beta_perform)) }
    let(:runner) { Busybee::Runner::Multi.new([alpha_class, beta_class], client: gateway.client) }
    let(:alpha) { runner.runners.first }
    let(:beta) { runner.runners.last }

    after { stream_gate.close }

    def worker(type, mode, &perform)
      Class.new(Busybee::Worker) do
        job_type type
        worker_mode mode
        define_method(:perform, &perform)
      end
    end

    def beta_brackets
      Concurrent::Array.new.tap do |brackets|
        Busybee::Hooks.on_job_activated(job_type: "beta") { |job| brackets << [:activated, job.key] }
        Busybee::Hooks.on_job_executed(job_type: "beta") { |job| brackets << [:executed, job.key] }
        Busybee::Hooks.on_job_not_executed(job_type: "beta") { |job| brackets << [:not_executed, job.key] }
      end
    end

    # Alpha's stream reader meets an unrecoverable error after a graceful stop
    # has begun, which alone would not end its run in a raise. Beta is in
    # perform with a second job in hand when it lands.
    context "when one worker meets an unrecoverable error after a stop" do
      let(:alpha_mode) { :streaming }
      let(:alpha_activating) { Concurrent::Event.new }
      let(:stopped) { Concurrent::Event.new }
      let(:alpha_perform) { proc { {} } }
      let(:beta_perform) do
        activating = alpha_activating
        stop_made = stopped
        multi = -> { runner }
        sibling = -> { alpha }
        waiter = method(:wait_until)
        proc do
          activating.wait(5)
          multi.call.stop!(reason: :sigterm)
          stop_made.set
          waiter.call { sibling.call.send(:post_stop_error) }
          {}
        end
      end

      before do
        gate = stream_gate
        gateway.on(:stream_activated_jobs) do
          Enumerator.new do |yielder|
            yielder << wire_job(10, "alpha")
            gate.pop
          end
        end
        poll_for("beta", 1, 2)
        activating = alpha_activating
        stop_made = stopped
        Busybee::Hooks.on_job_activated(job_type: "alpha") do |_job|
          activating.set
          stop_made.wait(5)
          raise NoMemoryError, "failed to allocate memory"
        end
      end

      it "runs no more of the other worker's job hooks and sends the engine nothing back" do
        brackets = beta_brackets
        run_to_completion

        aggregate_failures do
          expect(brackets).to eq([[:activated, 1]])
          expect(gateway.received(:fail_job)).to be_empty
        end
      end
    end

    # Alpha's start hook fails unrecoverably once beta has a batch in hand.
    context "when one worker fails to start" do
      let(:alpha_mode) { :polling }
      let(:beta_activated) { Concurrent::Event.new }
      let(:alpha_perform) { proc { {} } }
      let(:beta_perform) do
        sibling = -> { beta }
        waiter = method(:wait_until)
        proc do
          waiter.call { sibling.call.stopping? }
          {}
        end
      end

      before do
        poll_for("beta", 1, 2)
        activated = beta_activated
        Busybee::Hooks.on_job_activated(job_type: "beta") { |_job| activated.set }
        Busybee::Hooks.on_worker_started(worker_class: "AlphaWorker") do |_status|
          activated.wait(5)
          raise NoMemoryError, "failed to allocate memory"
        end
      end

      it "sends the engine nothing back for the other worker's job in hand" do
        brackets = beta_brackets
        raised = run_to_completion

        aggregate_failures do
          expect(raised).to be_a(NoMemoryError)
          expect(brackets).to eq([[:activated, 1]])
          expect(gateway.received(:fail_job)).to be_empty
        end
      end
    end

    # Alpha's stream closes cleanly with jobs still buffered, and its drain
    # meets an unrecoverable error; its run still returns normally. Beta is
    # idle, polling an empty queue.
    # Alpha's stop finds jobs it never started, and handing one back fails
    # unrecoverably in its on_job_not_executed hook; its run still returns
    # normally. Beta is idle, polling an empty queue. The handback happens in
    # one of two places, and both must end the same way.
    shared_examples "a handback failure that ends the process" do
      it "kills the other workers too" do
        statuses = shutdown_statuses_from { expect(run_to_completion(seconds: 5)).to be_nil }

        expect(statuses.find { |status| status.worker_class == beta_class }.reason).to eq(:crash)
      end
    end

    context "when one worker hands a job back unrecoverably" do
      let(:alpha_mode) { :streaming }
      let(:beta_perform) { proc { {} } }

      before do
        poll_for("beta")
        Busybee::Hooks.on_job_not_executed(job_type: "alpha") { |_job| raise NoMemoryError, "failed to allocate memory" }
      end

      # Job 1 is in perform when the stream sends jobs 2 and 3 and ends; perform
      # returns once that close has stopped Alpha, so 2 and 3 go back in the drain.
      context "when it goes back in the drain" do
        let(:alpha_perform) do
          gate = stream_gate
          sibling = -> { alpha }
          waiter = method(:wait_until)
          proc do
            gate << :performing
            waiter.call { sibling.call.stopping? }
            {}
          end
        end

        before do
          gate = stream_gate
          gateway.on(:stream_activated_jobs) do
            Enumerator.new do |yielder|
              yielder << wire_job(1, "alpha")
              gate.pop
              yielder << wire_job(2, "alpha")
              yielder << wire_job(3, "alpha")
            end
          end
        end

        it_behaves_like "a handback failure that ends the process"
      end

      # The stop lands between Alpha's loop checking for one and taking job 1
      # off its buffer, so job 1 goes back from the loop itself.
      context "when it goes back from the run loop" do
        let(:alpha_perform) { proc { {} } }

        before do
          gate = stream_gate
          gateway.on(:stream_activated_jobs) do
            Enumerator.new do |yielder|
              yielder << wire_job(1, "alpha")
              gate.pop
            end
          end
          stopping = -> { alpha }
          stop_on_first_take = Class.new(Queue) do
            define_method(:pop) do |*args, **options|
              super(*args, **options).tap { |item| stopping.call.stop!(reason: :sigterm) unless item == :stop }
            end
          end
          alpha.instance_variable_set(:@job_buffer, stop_on_first_take.new)
        end

        it_behaves_like "a handback failure that ends the process"
      end
    end
  end
end
