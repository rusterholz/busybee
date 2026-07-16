# frozen_string_literal: true

require "concurrent"

# End-to-end coverage for the worker-lifecycle hooks firing against a live Zeebe
# cluster. A real Polling runner starts, processes a job, and is stopped; each of
# the four moments (started → stop_requested → stopping → shutdown) fires its
# on_worker_* hook with a real Worker::Status carrying live identity, timing, and
# counters. The unit specs drive this with a synthetic runner; here the full
# Runner#run! / #stop! lifecycle runs against a real gateway.
RSpec.describe "Worker lifecycle hooks", :integration do
  include Busybee::Testing::Helpers

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new(worker_mode: :polling).resolve_for(worker_class) }
  let(:runner) do
    Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: client)
  end

  let(:worker_class) do
    Class.new(Busybee::Worker) do
      job_type "process-order"
      output :processed
      polling request_timeout: 1_000
      define_method(:perform) { { "processed" => true } }
    end
  end

  # Worker hooks fire on the runner thread (started/stopping/shutdown) and the
  # stopping thread (stop_requested); capture each moment's Status snapshot
  # thread-safely. job_executed lets the test wait until real work happened
  # (so the counters are non-zero) before signalling stop.
  let(:fired) { Concurrent::Hash.new }
  let(:job_executed) { Concurrent::AtomicBoolean.new(false) }

  def worker_hook_types
    %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown]
  end

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    Busybee::Hooks.reset!
    worker_hook_types.each do |type|
      moment = type.to_s.delete_prefix("on_worker_").to_sym
      Busybee.public_send(type) { |worker| fired[moment] = worker }
    end
    Busybee.on_job_executed { job_executed.make_true }

    client.deploy_process(job_bpmn_path)
  end

  after { Busybee::Hooks.reset! }

  it "fires all four lifecycle moments, each with a Worker::Status" do
    run_one_job

    aggregate_failures do
      %i[started stop_requested stopping shutdown].each do |moment|
        expect(fired[moment]).to be_a(Busybee::Worker::Status),
                                 "expected #{moment} to fire with a Worker::Status"
      end
    end
  end

  it "presents identity, timing, and counters on the shutdown status" do
    run_one_job

    status = fired[:shutdown]
    aggregate_failures do
      expect(status.worker_class).to eq(worker_class)
      expect(status.worker_mode).to eq(:polling)
      expect(status.job_type).to eq("process-order")
      expect(status.worker_name).to eq(Busybee.worker_name)
      expect(status.started_at).to be_a(Time)
      expect(status.stop_requested_at).to be_a(Time)
      expect(status.stopping_at).to be_a(Time)
      expect(status.shutdown_at).to be_a(Time)
      expect(status.uptime_s).to be_a(Float)
      expect(status.reason).to eq(:signal) # clean stop, no error
      expect(status.error).to be_nil
      expect(status.total_job_count).to be >= 1
      expect(status.failed_job_count).to eq(0) # the worker completed cleanly
    end
  end

  it "reports a not-yet-reached moment as nil at started (snapshot semantics)" do
    run_one_job

    status = fired[:started]
    aggregate_failures do
      expect(status.started_at).to be_a(Time)
      expect(status.stopping_at).to be_nil
      expect(status.shutdown_at).to be_nil
    end
  end

  private

  def run_one_job(timeout: 15)
    with_process_instance("job-process") do
      runner_thread = Thread.new { runner.run! }
      wait_until(timeout: timeout) { job_executed.true? }
      runner.stop!
      runner_thread.join(5)
    end
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end
end
