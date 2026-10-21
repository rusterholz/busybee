# frozen_string_literal: true

# What an operator reads at info (and debug) for a worker's ordinary life, from
# a real polling runner and client: its start and stop, each job it activates,
# completes or fails, and each job it hands back.
RSpec.describe "a worker's ordinary life in the log", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    stub_const("LogWorker", Class.new(Busybee::Worker) do
      job_type "log_job"
      worker_mode :polling

      def perform = {}
    end)
  end
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "log_job", key: key, retries: 3)

  # The first poll hands over the jobs given; the second stops the worker.
  def poll_once(*keys)
    polls = 0
    stopping = -> { runner }
    gateway.on(:activate_jobs) do
      polls += 1
      if polls == 1
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: keys.map { |key| wire_job(key) })]
      else
        stopping.call.stop!(reason: :sigterm)
        [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
      end
    end
  end

  # The poll stops the worker, then hands over a job it must hand back.
  def poll_into_a_stop(key)
    stopping = -> { runner }
    gateway.on(:activate_jobs) do
      stopping.call.stop!(reason: :sigterm)
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(key)])]
    end
  end

  it "says when the worker starts and stops, and what became of each job" do
    poll_once(1)

    lines = capture_busybee_log { run_to_completion }

    expect(lines).to eq([
                          "INFO [busybee] Started LogWorker (polling, job type log_job)",
                          "DEBUG [busybee] Activated log_job job #1",
                          "INFO [busybee] Completed log_job job #1",
                          "INFO [busybee] Stopping LogWorker (sigterm)",
                          "INFO [busybee] Stopped LogWorker (sigterm)"
                        ])
  end

  it "leaves activation out at info" do
    poll_once(1)

    lines = capture_busybee_log(level: Logger::INFO) { run_to_completion }

    expect(lines.grep(/Activated/)).to be_empty
  end

  it "says when a job fails, with its retries left and why" do
    worker_class.define_method(:perform) { raise "out of stock" }
    poll_once(1)

    lines = capture_busybee_log { run_to_completion }

    failed = "INFO [busybee] Failed log_job job #1, 2 retries left (RuntimeError: out of stock)"
    expect(lines.grep(/job #1/)).to eq(["DEBUG [busybee] Activated log_job job #1", failed])
  end

  it "says when it hands a job back during a stop" do
    poll_into_a_stop(2)

    lines = capture_busybee_log { run_to_completion }

    expect(lines).to include("INFO [busybee] Handed back log_job job #2, LogWorker shutting down (sigterm)")
  end

  it "says when it hands back the job whose activation hook declared the worker unhealthy" do
    poll_once(3)
    Busybee.on_job_activated { |_job| raise Busybee::Worker::Shutdown, "replica lag too high" }

    lines = capture_busybee_log { run_to_completion }

    expect(lines).to include("INFO [busybee] Handed back log_job job #3, LogWorker shutting down (unhealthy)")
  end

  it "says only that a handback failed, when it did" do
    gateway.on(:fail_job) { raise GRPC::Unavailable, "broker went away" }
    poll_into_a_stop(2)

    lines = capture_busybee_log { run_to_completion }

    aggregate_failures do
      expect(lines.grep(/Handed back/)).to be_empty
      expect(lines.grep(/\AWARN \[busybee\] Failed to hand log_job job #2 back during shutdown/).size).to eq(1)
    end
  end
end
