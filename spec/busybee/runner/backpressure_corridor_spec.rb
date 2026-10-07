# frozen_string_literal: true

require "concurrent"

# Drives a real runner, with a real client, against a gateway that reports
# backpressure. Nothing of busybee's is doubled, so what these examples record is
# the behavior a deployed worker actually gets.
RSpec.describe "gateway backpressure reaching a runner", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "corridor_worker"

      # No delay at all, so the backoff costs the suite nothing: what these
      # examples pin is the error's type and its classification. The magnitude is
      # a separate claim with its own example, which pays for a real pause.
      backpressure_delay 0

      def perform; end
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  around { |example| isolate_busybee_hooks { example.run } }

  describe "the polling runner" do
    let(:runner) do
      Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    context "when the gateway reports a configured backpressure status" do
      before do
        polls = 0
        gateway.on(:activate_jobs) do
          polls += 1
          raise GRPC::ResourceExhausted, "broker under pressure" if polls == 1

          runner.stop!
          []
        end
      end

      it "backs off and polls again rather than letting the status escape the loop" do
        status = shutdown_status_from { run_to_completion }

        expect(status.backpressure_count).to eq(1)
        expect(gateway.received(:activate_jobs).size).to eq(2)
      end

      it "ends on the caller's own stop rather than as an internal defect" do
        expect(shutdown_status_from { run_to_completion }.reason).to eq(:signal)
      end
    end

    # Unavailable is nothing special here — it stands in for any status absent
    # from Busybee.backpressure_statuses. Which statuses back off is configuration,
    # not a property of the status; the translation below is neither.
    context "when the gateway reports a status outside Busybee.backpressure_statuses" do
      before { gateway.on(:activate_jobs) { raise GRPC::Unavailable, "broker went away" } }

      it "surfaces it as the error type with_each_job documents, status intact" do
        raised = run_to_completion

        expect(raised).to be_a(Busybee::GRPC::Error)
        expect(raised.grpc_status).to eq(:unavailable)
      end

      it "classifies the ending as a gateway event rather than a crash" do
        expect(shutdown_status_from { run_to_completion }.reason).to eq(:gateway_error)
      end
    end

    # The only example here that pays for a real backoff: "backs off" and "backs
    # off for the right length of time" are separate claims.
    #
    # Kept small because a regression sleeps the configured number as *seconds*,
    # uninterruptibly (kill! doesn't reach a sleeping thread), so this value is
    # also how long a broken build hangs. The default's magnitude is pinned
    # without waiting, in durations_spec.rb.
    context "with a backpressure_delay long enough to measure" do
      let(:worker_class) do
        Class.new(Busybee::Worker) do
          job_type "corridor_worker"
          worker_mode :polling
          backpressure_delay 250

          def perform; end
        end
      end

      before do
        polls = 0
        gateway.on(:activate_jobs) do
          polls += 1
          raise GRPC::ResourceExhausted, "broker under pressure" if polls == 1

          runner.stop!
          []
        end
      end

      it "pauses for a quarter second, not a quarter thousand" do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run_to_completion
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(elapsed).to be_between(0.2, 3.0)
      end
    end
  end

  # Hybrid meets the same gateway on the same fetch call, through its own loop:
  # the drain phase polls with_each_job while the pump thread holds the stream
  # open. The stream has to stay open for the drain to be reached at all — a
  # stream that ends stops the runner from the pump's ensure.
  describe "the hybrid runner's drain phase" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "corridor_worker"
        worker_mode :hybrid
        backpressure_delay 0

        def perform; end
      end
    end

    let(:runner) do
      Busybee::Runner::Hybrid.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    # Held open by a blocking pop; closing the queue ends the stream naturally,
    # which releases the gateway's handler thread before the gateway is stopped.
    let(:stream_gate) { Queue.new }

    before do
      gateway.on(:stream_activated_jobs) { Enumerator.new { |_yielder| stream_gate.pop } }

      polls = 0
      gateway.on(:activate_jobs) do
        polls += 1
        raise GRPC::ResourceExhausted, "broker under pressure" if polls == 1

        runner.stop!
        []
      end
    end

    after { stream_gate.close }

    it "backs off and drains again rather than letting the status escape the loop" do
      status = shutdown_status_from { run_to_completion }

      expect(status.backpressure_count).to eq(1)
      expect(gateway.received(:activate_jobs).size).to eq(2)
    end

    it "ends on the caller's own stop rather than as an internal defect" do
      expect(shutdown_status_from { run_to_completion }.reason).to eq(:signal)
    end
  end

  # The composed claim, and the reason it gets its own corridor: the container's
  # cascade is already pinned for an error that escapes a child, and a runner
  # corridor is already pinned for backpressure. Only driving both together
  # answers whether one worker's backpressure takes the whole process down.
  describe "a Multi container where one worker meets backpressure" do
    let(:pressured_worker) do
      Class.new(Busybee::Worker) do
        job_type "corridor_pressured"
        worker_mode :polling
        backpressure_delay 0

        def perform; end
      end
    end

    let(:sibling_worker) do
      Class.new(Busybee::Worker) do
        job_type "corridor_sibling"
        worker_mode :polling

        def perform; end
      end
    end

    let(:runner) { Busybee::Runner::Multi.new([pressured_worker, sibling_worker], client: gateway.client) }

    before do
      pressured_polls = Concurrent::AtomicFixnum.new(0)

      gateway.on(:activate_jobs) do |request|
        if request.type == "corridor_pressured"
          raise GRPC::ResourceExhausted, "broker under pressure" if pressured_polls.increment == 1

          # Back for a second poll: it survived the status, so the run can end.
          runner.stop!
        end
        []
      end
    end

    it "keeps the container running instead of cascading the status to its siblings" do
      expect(run_to_completion).to be_nil
    end

    it "ends both workers on the container's stop, with the backoff recorded" do
      statuses = shutdown_statuses_from { run_to_completion }

      expect(statuses.map(&:reason)).to all(eq(:signal))
      expect(statuses.find { |s| s.worker_class == pressured_worker }.backpressure_count).to eq(1)
    end
  end
end
