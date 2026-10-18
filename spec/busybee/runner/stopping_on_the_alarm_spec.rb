# frozen_string_literal: true

# A worker that has not been stopped, in a process told to exit immediately by
# another worker's kill, with a real client.
RSpec.describe "a worker in a process told to exit immediately", :gateway do # rubocop:disable RSpec/DescribeClass
  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "stopping_on_the_alarm"
      worker_mode :polling

      def perform = {}
    end
  end

  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) { Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: gateway.client) }
  let(:sibling) do
    sibling_class = Class.new(Busybee::Worker) { job_type "sibling" }
    Busybee::Runner::Polling.new(sibling_class, runtime_config: runtime_config, client: gateway.client)
  end

  around { |example| isolate_busybee_hooks { example.run } }

  before do
    gateway.on(:activate_jobs) do
      sleep 0.05
      [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
    end
  end

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  it "counts as stopping" do
    sibling.kill!

    expect([runner.stopping?, runner.stop_reason]).to eq([true, nil])
  end

  it "leaves its polling loop" do
    killer = Thread.new do
      wait_until { runner.running? }
      sleep 0.05
      sibling.kill!
    end

    expect(run_to_completion(seconds: 3)).to be_nil
    killer.join(3)
  end

  it "doesn't start" do
    started = []
    Busybee::Hooks.on_worker_started(job_type: "stopping_on_the_alarm") { |_status| started << :started }
    sibling.kill!

    expect([run_to_completion(seconds: 3), started]).to eq([nil, []])
  end
end
