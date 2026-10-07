# frozen_string_literal: true

# A worker meeting an error it cannot recover from (NoMemoryError and its kind,
# below Runner::RECOVERABLE_ERRORS), with a real client: work in hand is dropped
# for the engine to reclaim on activation timeout, and the worker says why.
RSpec.describe "a worker meeting an unrecoverable error", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
    gateway.on(:fail_job) { Busybee::GRPC::FailJobResponse.new }
  end

  def wire_job(key) = FaultInjectionGateway.activated_job(type: "unrecoverable_corridor", key: key)

  def record_worker_moments
    Concurrent::Array.new.tap do |moments|
      %i[on_worker_stopping on_worker_shutdown].each do |type|
        Busybee::Hooks.public_send(type) { |status| moments << [type, status.reason, status.error&.class] }
      end
    end
  end

  describe "raised by perform" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "unrecoverable_corridor"
        worker_mode :polling

        def perform = raise(NoMemoryError, "failed to allocate memory")
      end
    end

    let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }

    before do
      gateway.on(:activate_jobs) { [Busybee::GRPC::ActivateJobsResponse.new(jobs: [wire_job(1), wire_job(2)])] }
    end

    it "still closes the activation of the job it was running" do
      brackets = record_job_brackets
      run_to_completion

      expect(brackets).to eq([[:activated, 1], [:executed, 1]])
    end

    it "sends the engine nothing about that job, nor about the rest of its batch" do
      run_to_completion

      expect(gateway.received(:fail_job) + gateway.received(:complete_job)).to be_empty
    end

    it "ends the worker on that error, through both closing moments" do
      moments = record_worker_moments

      expect(run_to_completion).to be_a(NoMemoryError)
      expect(moments).to eq([%i[on_worker_stopping crash] + [NoMemoryError],
                             %i[on_worker_shutdown crash] + [NoMemoryError]])
    end
  end
end
