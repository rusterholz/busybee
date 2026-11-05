# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::PickAndPackWorker do
  around do |example|
    original = Rails.application.config.x.demo.simulation_speed
    Rails.application.config.x.demo.simulation_speed = 10_000.0
    example.run
    Rails.application.config.x.demo.simulation_speed = original
  end

  let(:client) { build_test_client }
  let(:held) { Concurrent::AtomicFixnum.new }

  # Every picker busy, so a dispatched pick waits, unsettled, until released; and
  # the pick finishes inside its own example, never making its calls in a later one.
  around do |example|
    held.value = pickers.drain_permits
    example.run
  ensure
    free_pickers
  end

  def pickers = described_class::PICKERS
  def pick_job = build_test_job(type: described_class.job_type, variables: { item_count: 3 }, client: client)

  def release_held
    count = held.value
    held.value = 0
    pickers.release(count) if count.positive?
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # The picker settles the job on its own thread, so the job is the thing to wait on.
  def await_resolution(job) = job.tap { wait_until(5) { job.resolved? } }

  # Let the waiting pick run, then wait for its picker to come back.
  def free_pickers
    release_held
    wait_until(5) { pickers.available_permits == 3 }
  end

  # Started, not run whole: stopping the worker hands back whatever is still in
  # flight, so these keep it up until the picker is done.
  context "with the worker running" do
    let(:worker) { start_test_worker(described_class, client: client) }

    after { worker.stop! }

    # perform queues the work and returns immediately, so the job is unresolved
    # when the worker is done with it and nothing is auto-completed on its behalf;
    # the picker completes it once it gets to run.
    it "returns before the picking is done, and the picker completes the job" do
      job = execute_worker(worker, job: pick_job)

      expect(job.result).to be_nil
      expect(job).to be_ready

      free_pickers

      expect(await_resolution(job)).to be_complete
    end
  end

  # The worker hooks back on: the handback rides on_worker_stopping.
  context "when the worker stops with a pick still waiting", without_busybee_hooks: %i[job call] do
    it "hands the job back to the engine with its retries intact" do
      job = execute_worker(described_class, job: pick_job)

      expect(job).to be_failed
      expect(job.retries).to eq(3)
      expect(job.error_message).to eq("Worker shutting down")
      expect(client.received(:fail_job).map(&:retries)).to eq([3])
    end

    # The race: the picker finishes while the handback's call is still on the wire,
    # before the job knows it is settled, so only the claim can stop a second call.
    it "doesn't also complete a job the picker finishes mid-handback" do
      client.on(:fail_job) do
        free_pickers
        wait_until(0.5) { client.received(:complete_job).any? }
        Busybee::GRPC::FailJobResponse.new
      end

      job = execute_worker(described_class, job: pick_job)

      expect(client.received(:complete_job)).to be_empty
      expect(job).to be_failed
    end
  end
end
