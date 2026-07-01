# frozen_string_literal: true

require "concurrent"

# End-to-end coverage for the job lifecycle hooks firing against a live Zeebe
# cluster. The unit specs drive the hook machinery with synthetic targets; this
# proves the full wiring — a real Runner activates real jobs, a real Worker
# performs them, and every registered hook fires with a real Busybee::Job
# carrying accurate status, timestamps, durations, and outcome data.
RSpec.describe "Job lifecycle hooks", :integration do
  include Busybee::Testing::Helpers

  let(:job_bpmn_path) { File.expand_path("../../fixtures/job_process.bpmn", __dir__) }
  let(:client) { local_busybee_client }
  let(:runtime_config) { Busybee::RuntimeConfig.new.resolve_for(worker_class) }
  let(:runner) do
    Busybee::Runner::Polling.new(worker_class, runtime_config: runtime_config, client: client)
  end

  # Thread-safe capture keyed by hook type. Each entry is an immutable snapshot
  # taken at the instant the hook fired — the Job mutates across its lifecycle,
  # so retaining the live reference would observe only its final state.
  let(:fired) { Concurrent::Hash.new }

  around do |example|
    original = Busybee.credential_type
    Busybee.credential_type = :insecure
    example.run
    Busybee.credential_type = original
  end

  before do
    Busybee::Hooks.reset!
    job_hook_types.each { |type| fired[type] = Concurrent::Array.new }
    register_lifecycle_hooks

    client.deploy_process(job_bpmn_path)
  end

  after { Busybee::Hooks.reset! }

  context "with an auto-completing worker" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "process-order"
        output :processed
        polling request_timeout: 1_000
        define_method(:perform) { { "processed" => true } }
      end
    end

    it "fires every lifecycle hook exactly once" do
      run_one_job

      job_hook_types.each do |type|
        expect(fired[type].size).to eq(1),
                                    "expected #{type} to fire once, fired #{fired[type].size} times"
      end
    end

    it "presents a :ready, minimally-stamped job at activation" do
      run_one_job

      activation = fired[:on_job_activated].first
      aggregate_failures do
        expect(activation[:status]).to eq(:ready)
        expect(activation[:job_type]).to eq("process-order")
        expect(activation[:bpmn_process_id]).to eq("job-process")
        expect(activation[:source]).to eq(:poll)
        expect(activation[:buffered]).to be(false) # polling jobs are never buffered
        expect(activation[:activated_at]).to be_a(Time)
        expect(activation[:executed_at]).to be_nil # not stamped until after execution
      end
    end

    it "presents a :complete, fully-resolved job with its result at execution" do
      run_one_job

      executed = fired[:on_job_executed].first
      expect(executed[:status]).to eq(:complete)
      expect(executed[:resolved]).to be(true)
      expect(executed[:result]).to include("processed" => true)
      expect(executed[:activated_at]).to be_a(Time)
      expect(executed[:resolved_at]).to be_a(Time)
      expect(executed[:executed_at]).to be_a(Time)
      assert_timestamps_ordered(executed)
      assert_durations_non_negative(executed)
    end
  end

  context "with a manually-completing worker" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "process-order"
        polling request_timeout: 1_000
        define_method(:perform) { job.complete!("manual" => true) }
      end
    end

    it "records a completed job carrying the manual result" do
      run_one_job

      executed = fired[:on_job_executed].first
      expect(executed[:status]).to eq(:complete)
      expect(executed[:result]).to include("manual" => true)
      assert_durations_non_negative(executed)
    end
  end

  context "with a worker that raises" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "process-order"
        polling request_timeout: 1_000
        define_method(:perform) { raise "boom" }
      end
    end

    it "records a failed job with the error attached" do
      run_one_job

      expect(fired[:after_job]).not_to be_empty
      executed = fired[:on_job_executed].first
      expect(executed[:status]).to eq(:failed)
      expect(executed[:resolved]).to be(true)
      expect(executed[:error_message]).to include("boom")
    end
  end

  context "with a worker that throws a BPMN error" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "process-order"
        polling request_timeout: 1_000
        define_method(:perform) { job.throw_bpmn_error!("ORDER_REJECTED", "rejected by demo worker") }
      end
    end

    it "records an errored job with the BPMN error code" do
      run_one_job

      executed = fired[:on_job_executed].first
      expect(executed[:status]).to eq(:error)
      expect(executed[:resolved]).to be(true)
      expect(executed[:error_code]).to eq("ORDER_REJECTED")
    end
  end

  context "with prefiltered hooks" do
    let(:worker_class) do
      Class.new(Busybee::Worker) do
        job_type "process-order"
        polling request_timeout: 1_000
        define_method(:perform) { { "processed" => true } }
      end
    end

    before do
      fired[:matching_job_type]    = Concurrent::Array.new
      fired[:nonmatching_job_type] = Concurrent::Array.new
      fired[:matching_process]     = Concurrent::Array.new
      f = fired

      Busybee.after_job(job_type: "process-order")    { |job| f[:matching_job_type] << job.key }
      Busybee.after_job(job_type: "no-such-job-type") { |job| f[:nonmatching_job_type] << job.key }
      Busybee.after_job(bpmn_process_id: "job-process") { |job| f[:matching_process] << job.key }
    end

    it "fires a hook whose job_type filter matches the job" do
      run_one_job

      expect(fired[:matching_job_type]).not_to be_empty
    end

    it "does not fire a hook whose job_type filter does not match" do
      run_one_job

      expect(fired[:nonmatching_job_type]).to be_empty
    end

    it "fires a hook whose bpmn_process_id filter matches the job" do
      run_one_job

      expect(fired[:matching_process]).not_to be_empty
    end
  end

  private

  def job_hook_types
    %i[on_job_activated before_job around_job after_job on_job_executed around_job_execution]
  end

  def register_lifecycle_hooks
    f = fired
    %i[on_job_activated before_job after_job on_job_executed].each do |type|
      Busybee.public_send(type) { |job| f[type] << snapshot(job) }
    end
    register_around_hook(:around_job)
    register_around_hook(:around_job_execution)
  end

  # around_job / around_job_execution receive the continuation as a second
  # argument and must call it to run the wrapped work.
  def register_around_hook(type)
    f = fired
    Busybee.public_send(type) do |job, continue|
      f[type] << snapshot(job)
      continue.call
    end
  end

  # Fields whose value identifies the job's observable state. Read by their
  # public accessors (timestamp readers default to their UTC form).
  def snapshot_fields
    %i[
      key job_type bpmn_process_id status source buffered
      result error_message error_code
      activated_at execution_started_at perform_started_at
      perform_finished_at resolved_at executed_at
      total_duration_ms perform_duration_ms execution_duration_ms
    ]
  end

  # Immutable view of the job's observable state at the moment a hook fired —
  # the Job mutates across its lifecycle, so we capture rather than retain it.
  def snapshot(job)
    snapshot_fields.to_h { |field| [field, job.public_send(field)] }.
      merge(resolved: job.resolved?)
  end

  def assert_timestamps_ordered(snap)
    stamped = %i[
      activated_at execution_started_at perform_started_at
      perform_finished_at resolved_at executed_at
    ].map { |name| snap[name] }.compact

    expect(stamped).to all(be_a(Time))
    expect(stamped).to eq(stamped.sort)
  end

  def assert_durations_non_negative(snap)
    %i[total_duration_ms perform_duration_ms execution_duration_ms].each do |name|
      next if snap[name].nil?

      expect(snap[name]).to be >= 0
    end
  end

  def run_one_job(timeout: 15)
    with_process_instance("job-process") do
      runner_thread = Thread.new { runner.run! }
      wait_until(timeout: timeout) { fired[:on_job_executed].any? }
      runner.stop!
      runner_thread.join(5)
    end
  end

  def wait_until(timeout: 5, poll: 0.1)
    deadline = Time.now + timeout
    sleep poll until yield || Time.now > deadline
  end
end
