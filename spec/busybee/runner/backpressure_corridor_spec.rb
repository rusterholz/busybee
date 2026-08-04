# frozen_string_literal: true

require "timeout"

# Drives a real runner, with a real client, against a gateway that reports
# backpressure. Nothing of busybee's is doubled, so what these examples record is
# the behavior a deployed worker actually gets.
RSpec.describe "gateway backpressure reaching a runner", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "corridor_worker"

      def perform; end
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  before do
    gateway.on(:activate_jobs) { raise GRPC::ResourceExhausted, "broker under pressure" }
  end

  after { Busybee::Hooks.reset! }

  describe "the polling runner" do
    let(:runner) do
      Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client)
    end

    # The timeout is a guard, not an assertion: if the status were classified as
    # backpressure the loop would sleep instead of raising, and the example would
    # otherwise park for the length of that sleep.
    def run_to_completion
      Timeout.timeout(15) { runner.run! }
    rescue GRPC::BadStatus => e
      e
    end

    it "lets the raw gateway status escape the loop's Busybee::GRPC::Error rescue" do
      raised = run_to_completion

      expect(raised).to be_a(GRPC::BadStatus)
      expect(raised).not_to be_a(Busybee::GRPC::Error)
    end

    it "never reaches the backpressure backoff" do
      expect(shutdown_status_from { run_to_completion }.backpressure_count).to eq(0)
    end

    # Backpressure is an engine-driven ending, but the raw status misses the
    # Busybee::GRPC::Error arm of reason_for and lands in the catch-all instead.
    it "reports the ending as an internal defect rather than a gateway event" do
      expect(shutdown_status_from { run_to_completion }.reason).to eq(:crash)
    end
  end

  # The shutdown hook is the public window onto a runner's final counters, and it
  # fires from run!'s ensure on every exit path, including this one.
  def shutdown_status_from
    captured = nil
    Busybee::Hooks.on_worker_shutdown { |status| captured = status }
    yield
    captured
  end
end
