# frozen_string_literal: true

require_relative "../rails_helper"

# "What happens when the broker misbehaves?" — the fault axis, crossing the job,
# worker and call lifecycles at once. An adopter has exactly our own error-path
# questions ("does my shutdown_on actually fire?", "what does my after_call see
# when the completion is rejected?"), and answering them by stubbing the client
# tests a belief about the gateway rather than the client.
#
# Here the faults are injected at the wire, so everything above it is the real
# thing: translation, retry, autofail, the teardown, and the demo's own hooks.
RSpec.describe "Busybee hook faults" do # rubocop:disable RSpec/DescribeClass
  let(:client) { build_test_client }
  let(:observed) { [] }

  around do |example|
    with_isolated_hooks do
      %i[on_job_activated on_job_executed on_job_not_executed after_call].each do |type|
        Busybee::Hooks.register(type, ->(carrier) { observed << [type, carrier] })
      end
      example.run
    end
  end

  def fired = observed.map(&:first)
  def resolved_calls = observed.select { |entry| entry.first == :after_call }.map(&:last)

  def job(key:, type: "calculate_distance")
    build_test_job(key: key, type: type, bpmn_process_id: "deliver-shipment",
                   variables: { from_lat: 0, from_lon: 0, to_lat: 3, to_lon: 4 },
                   headers: { algorithm: "pythagorean" }, client: client)
  end

  def run(key, worker_class = Delivery::CalculateDistanceWorker, type: "calculate_distance")
    execute_worker(worker_class, job: job(key: key, type: type))
  end

  def worker_row(job_type = "calculate_distance")
    Monitoring::WorkerProcess.find_by(worker_name: Busybee.worker_name, job_type: job_type)
  end

  describe "when the broker rejects a job's completion" do
    # The work succeeded; only the report of it failed. So the job is NOT
    # autofailed — that would record a work failure that never happened and spend
    # a retry. It stays :ready and redelivers when the lease expires. The error is
    # still captured on the carrier, so a hook can see why the completion did not
    # land even though the job reports no resolution.
    before { client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" } }

    it "shows the failed call to after_call without failing the job" do
      run(9100)

      completion = resolved_calls.find { |call| call.rpc == :complete_job }
      expect(completion).to be_errored
      expect(completion.grpc_status).to eq(:internal)
      expect(completion.error).to be_a(Busybee::GRPC::Error)
      expect(resolved_calls.map(&:rpc)).not_to include(:fail_job)
    end

    it "leaves the job unresolved but carrying the reason, for on_job_executed to see" do
      run(9101)

      _, job = observed.find { |type, _| type == :on_job_executed }
      expect(job).to be_ready
      expect(job.error_message).to include("storage unavailable")
    end

    it "records the run as unresolved in the demo's monitoring, with the errored call beside it" do
      run(9102)

      expect(Monitoring::JobRun.find_by(job_key: 9102)).to have_attributes(
        status: "ready", error_message: include("storage unavailable")
      )
      expect(Monitoring::EngineCall.for_job(9102).pluck(:rpc, :status)).to include(%w[complete_job errored])
    end
  end

  describe "when the broker is under pressure as the job reports back" do
    # Set directly: under this spec harness busybee loads before Rails, so the
    # Railtie never applies config.x.busybee's retry settings.
    around do |example|
      enabled = Busybee.grpc_retry_enabled
      delay = Busybee.grpc_retry_delay
      Busybee.grpc_retry_enabled = true
      Busybee.grpc_retry_delay = 10
      example.run
    ensure
      Busybee.grpc_retry_enabled = enabled
      Busybee.grpc_retry_delay = delay
    end

    it "retries the completion, and the job lands" do
      pressured = false
      client.on(:complete_job) do
        next Busybee::GRPC::CompleteJobResponse.new if pressured

        pressured = true
        raise GRPC::ResourceExhausted, "injected"
      end

      expect(run(9200)).to be_complete

      completion = resolved_calls.sole
      expect(completion).to have_attributes(rpc: :complete_job, attempts: 2)
      expect(worker_row).to have_attributes(status: "shutdown", reason: "signal", total_job_count: 1)
    end
  end

  describe "when a job is in hand as the worker shuts down" do
    # A stop that arrives mid-batch puts the rest of it on the handback path: the
    # job is returned unworked, so it must stay :ready — a :failed status would
    # read as a job that ran and lost. Stopping from a hook stands in for the
    # signal that would arrive on its own thread in production.
    def handback_run(key)
      worker = start_test_worker(Delivery::CalculateDistanceWorker, client: client)
      Busybee::Hooks.register(:on_job_executed, ->(_job) { worker.stop! })
      execute_worker(worker, jobs: [job(key: key - 1000), job(key: key)])
    end

    it "hands it back unworked and closes the activation through on_job_not_executed" do
      handback_run(9300)

      handed_back = observed.select { |_, carrier| carrier.is_a?(Busybee::Job) && carrier.key == 9300 }.map(&:first)
      expect(handed_back).to eq(%i[on_job_activated on_job_not_executed])
      expect(Monitoring::JobRun.find_by(job_key: 9300)).to have_attributes(status: "ready", lifecycle_rank: 1,
                                                                           executed_at: be_present)
    end

    it "puts a failed handback's error on the worker carrier, not the job" do
      client.on(:fail_job) { raise GRPC::Internal, "broker unreachable" }

      handback_run(9301)

      _, job = observed.find { |type, _| type == :on_job_not_executed }
      expect(job).to be_ready
      expect(job.error_message).to be_nil
      expect(job.worker_status.error_message).to include("broker unreachable")
      expect(Monitoring::JobRun.find_by(job_key: 9301).error_message).to include("broker unreachable")
    end
  end

  describe "when a declared shutdown error is raised from the app's own hook" do
    # The demo's rollover hazard, exercised for real. It is disabled under test
    # because worker specs invoke perform directly, where an enabled hazard would
    # randomly fail unrelated specs — so this is the one place its actual
    # behavior can be asserted: enabled deliberately, for one run, with the roll
    # forced rather than sampled.
    around do |example|
      previous = Rails.application.config.x.demo.rollovers_enabled
      Rails.application.config.x.demo.rollovers_enabled = true
      example.run
    ensure
      Rails.application.config.x.demo.rollovers_enabled = previous
    end

    it "shuts the worker down gracefully as :unhealthy and fails the pending job" do
      allow(Sim::RolloverPolicy).to receive(:roll).and_return(0.5)

      expect { run(9400) }.to raise_error(Busybee::Worker::Shutdown)

      expect(Sim::Rollover).to be < StandardError
      expect(Busybee.shutdown_on_errors).to include(Sim::Rollover)
      expect(worker_row).to have_attributes(status: "shutdown", reason: "unhealthy",
                                            error_class: "Sim::Rollover")
      expect(Monitoring::JobRun.find_by(job_key: 9400).status).to eq("failed")
    end

    it "exempts the sim workers by job, not by wiring" do
      allow(Sim::RolloverPolicy).to receive(:roll).and_return(0.5)

      run(9401, Sim::PickAndPackWorker, type: "simulate_pick_and_pack")

      expect(fired).to include(:on_job_executed)
      expect(worker_row("simulate_pick_and_pack")).to have_attributes(reason: "signal")
    end
  end
end
