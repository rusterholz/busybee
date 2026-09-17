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
    Busybee::Hooks.isolated do
      %i[on_job_activated on_job_executed on_job_not_executed after_call].each do |type|
        Busybee::Hooks.register(type, ->(carrier) { observed << [type, carrier] })
      end
      example.run
    end
  end

  def fired = observed.map(&:first)
  def resolved_calls = observed.select { |entry| entry.first == :after_call }.map(&:last)

  def raw_job(key:, type: "calculate_distance")
    build_test_raw_job(key: key, type: type, bpmn_process_id: "deliver-shipment",
                       variables: { from_lat: 0, from_lon: 0, to_lat: 3, to_lon: 4 },
                       headers: { algorithm: "pythagorean" })
  end

  # A short backpressure delay: the default is two real seconds, and a spec that
  # exercises a back-off should cost milliseconds, not the production pause.
  def runner_for(worker_class = Delivery::CalculateDistanceWorker)
    Busybee::Runner::Polling.new(
      worker_class,
      runtime_config: Busybee::RuntimeConfig.new(worker_mode: :polling, backpressure_delay: 10),
      client: client
    )
  end

  # Program the poll as a script of batches: an Exception class is raised, an
  # array of protos is delivered, and :stop ends the run. Mirrors the gateway
  # harness's contract — the block is the handler.
  def poll_script(runner, *steps)
    queue = steps.dup
    client.on(:activate_jobs) do |_request|
      step = queue.shift
      raise step, "injected" if step.is_a?(Class)
      next [Busybee::GRPC::ActivateJobsResponse.new(jobs: step)] if step.is_a?(Array)

      runner.stop!(reason: :signal)
      []
    end
    runner
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
    it "shows the failed call to after_call without failing the job" do
      client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }
      runner = poll_script(runner_for, [raw_job(key: 9100)], :stop)

      runner.run!

      completion = resolved_calls.find { |call| call.rpc == :complete_job }
      expect(completion).to be_errored
      expect(completion.grpc_status).to eq(:internal)
      expect(completion.error).to be_a(Busybee::GRPC::Error)
      expect(resolved_calls.map(&:rpc)).not_to include(:fail_job)
    end

    it "leaves the job unresolved but carrying the reason, for on_job_executed to see" do
      client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }
      runner = poll_script(runner_for, [raw_job(key: 9101)], :stop)

      runner.run!

      _, job = observed.find { |type, _| type == :on_job_executed }
      expect(job).to be_ready
      expect(job.error_message).to include("storage unavailable")
    end

    it "records the run as unresolved in the demo's monitoring, with the errored call beside it" do
      client.on(:complete_job) { raise GRPC::Internal, "storage unavailable" }
      runner = poll_script(runner_for, [raw_job(key: 9102)], :stop)

      runner.run!

      expect(Monitoring::JobRun.find_by(job_key: 9102)).to have_attributes(
        status: "ready", error_message: include("storage unavailable")
      )
      expect(Monitoring::EngineCall.for_job(9102).pluck(:rpc, :status)).to include(%w[complete_job errored])
    end
  end

  describe "when the broker is under pressure" do
    it "backs off and keeps working rather than dying" do
      runner = poll_script(runner_for, GRPC::ResourceExhausted, [raw_job(key: 9200)], :stop)

      runner.run!

      expect(fired).to include(:on_job_activated, :on_job_executed)
      expect(worker_row).to have_attributes(status: "shutdown", reason: "signal",
                                            backpressure_count: 1, total_job_count: 1)
    end
  end

  describe "when a job is in hand as the worker shuts down" do
    # Stopping before the batch is yielded puts the runner on the handback path:
    # the job is returned unworked, so it must stay :ready — a :failed status
    # would read as a job that ran and lost.
    def handback_run(key)
      runner = runner_for
      queue = [[raw_job(key: key)]]
      client.on(:activate_jobs) do |_request|
        batch = queue.shift
        next [] unless batch

        runner.stop!(reason: :signal)
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: batch)]
      end
      runner.run!
      runner
    end

    it "hands it back unworked and closes the activation through on_job_not_executed" do
      handback_run(9300)

      expect(fired).to include(:on_job_activated, :on_job_not_executed)
      expect(fired).not_to include(:on_job_executed)
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
      runner = poll_script(runner_for, [raw_job(key: 9400)], :stop)

      expect { runner.run! }.to raise_error(Busybee::Worker::Shutdown)

      expect(Sim::Rollover).to be < StandardError
      expect(Busybee.shutdown_on_errors).to include(Sim::Rollover)
      expect(worker_row).to have_attributes(status: "shutdown", reason: "unhealthy",
                                            error_class: "Sim::Rollover")
      expect(Monitoring::JobRun.find_by(job_key: 9400).status).to eq("failed")
    end

    it "exempts the sim workers by job, not by wiring" do
      allow(Sim::RolloverPolicy).to receive(:roll).and_return(0.5)
      runner = poll_script(runner_for(Sim::PickAndPackWorker),
                           [raw_job(key: 9401, type: "simulate_pick_and_pack")], :stop)

      runner.run!

      expect(fired).to include(:on_job_executed)
      expect(worker_row("simulate_pick_and_pack")).to have_attributes(reason: "signal")
    end
  end
end
