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
  end

  # The run happens on its own thread and the future is not handed back, so the
  # job itself is the only thing to wait on.
  def await_resolution(job, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until job.resolved? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    job
  end

  it "returns before the run is done, leaving the job unresolved" do
    job = build_test_job(type: described_class.job_type, variables: { distance: 5.0 })

    expect(execute_worker(described_class, job: job).result).to be_nil
    expect(job).to be_ready

    await_resolution(job)
  end

  it "completes the job from the run once it finishes" do
    job = build_test_job(type: described_class.job_type, variables: { distance: 5.0 })

    execute_worker(described_class, job: job)

    expect(await_resolution(job)).to be_complete
  end
end
