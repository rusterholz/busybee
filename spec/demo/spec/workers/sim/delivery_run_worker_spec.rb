# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::DeliveryRunWorker do
  around do |example|
    original = Rails.application.config.x.demo.simulation_speed
    Rails.application.config.x.demo.simulation_speed = 10_000.0
    example.run
    Rails.application.config.x.demo.simulation_speed = original
  end

  # The driver semaphore is sized from Delivery::Driver.count and memoized on the
  # class, so with no drivers it has no permits and a run would block forever.
  # Give it one, and clear the memo so it is sized against this example's rows.
  before do
    Delivery::Driver.create!(name: "Sim Driver", total_mileage: 0.0)
    described_class.instance_variable_set(:@drivers_semaphore, nil)
    described_class.instance_variable_set(:@known_driver_count, nil)
    held.value = drivers.drain_permits # every driver out: a dispatched run waits, unsettled
  end

  # The run finishes inside its own example, never making its calls in a later one.
  after do
    free_drivers
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until drivers.available_permits == 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  let(:client) { build_test_client }
  let(:held) { Concurrent::AtomicFixnum.new }

  def drivers = described_class.drivers_semaphore
  def run_job = build_test_job(type: described_class.job_type, variables: { distance: 5.0 }, client: client)

  # The run settles the job on its own thread, so the job is the thing to wait on.
  def await_resolution(job, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until job.resolved? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    job
  end

  def free_drivers
    count = held.value
    held.value = 0
    drivers.release(count) if count.positive?
  end

  # Started, not run whole: stopping the worker hands back whatever is still in
  # flight, so this keeps it up until the run is done.
  context "with the worker running" do
    let(:worker) { start_test_worker(described_class, client: client) }

    after { worker.stop! }

    it "returns before the run is done, and the run completes the job" do
      job = execute_worker(worker, job: run_job)

      expect(job.result).to be_nil
      expect(job).to be_ready

      free_drivers

      expect(await_resolution(job)).to be_complete
    end
  end

  # The worker hooks back on: the handback rides on_worker_stopping.
  context "when the worker stops with a run still waiting", without_busybee_hooks: %i[job call] do
    it "hands the job back to the engine with its retries intact" do
      job = execute_worker(described_class, job: run_job)

      expect(job).to be_failed
      expect(job.retries).to eq(3)
      expect(job.error_message).to eq("Worker shutting down")
      expect(client.received(:fail_job).map(&:retries)).to eq([3])
    end
  end
end
