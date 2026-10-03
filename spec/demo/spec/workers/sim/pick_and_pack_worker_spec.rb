# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe Sim::PickAndPackWorker do
  around do |example|
    original = Rails.application.config.x.demo.simulation_speed
    Rails.application.config.x.demo.simulation_speed = 10_000.0
    example.run
    Rails.application.config.x.demo.simulation_speed = original
  end

  # The picker runs on its own thread and the future is not handed back, so the
  # job itself is the only thing to wait on.
  def await_resolution(job, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until job.resolved? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    job
  end

  # perform queues the work and returns immediately — the whole point of the
  # non-blocking shape — so the job is still unresolved when the worker is done
  # with it, and nothing is auto-completed on its behalf.
  it "returns before the picking is done, leaving the job unresolved" do
    job = build_test_job(type: described_class.job_type, variables: { item_count: 3 })

    expect(execute_worker(described_class, job: job).result).to be_nil
    expect(job).to be_ready

    await_resolution(job)
  end

  it "completes the job from the picker once it finishes" do
    job = build_test_job(type: described_class.job_type, variables: { item_count: 3 })

    execute_worker(described_class, job: job)

    expect(await_resolution(job)).to be_complete
  end
end
