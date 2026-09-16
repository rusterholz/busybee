# frozen_string_literal: true

require_relative "../rails_helper"

# "Does busybee call my hooks when I think it does?" — the choreography contract:
# which moments fire, in what order, carrying what. Distinct from the wiring
# question (would this hook match?) and from the hook-body question (what does the
# body do with the carrier?).
#
# Driven by a real Runner::Polling over an in-process gateway, so the fetch, the
# activation, perform, auto-completion and the teardown are all genuine paths. The
# call moments are the point: today nothing in the shipped Testing module can make
# a call hook fire at all, because its client is doubled above the seam they hang off.
RSpec.describe "Busybee hook choreography" do # rubocop:disable RSpec/DescribeClass
  let(:gateway) { InProcessGateway.new }
  let(:observed) { [] }

  # The demo's own hooks stay registered — this run exercises them too — so the
  # recorder writes inline rather than on its background thread.
  before do
    allow(Monitoring::Recorder).to receive(:executor).and_return(Concurrent::ImmediateExecutor.new)
  end

  around do |example|
    saved = Busybee::Hooks::HOOK_TYPES.to_h { |type| [type, Busybee::Hooks.hooks_for(type).dup] }
    observe_every_moment
    example.run
  ensure
    saved.each { |type, hooks| Busybee::Hooks.hooks_for(type).replace(hooks) }
  end

  # The three that wrap rather than observe, so they take (carrier, continue).
  def around_types = %i[around_perform around_job_execution around_call]

  # Append an observer at every one of the 14 moments. Appending rather than
  # replacing keeps the app's own hooks in the run, so this drives the demo's
  # real monitoring bracket at the same time.
  def observe_every_moment
    (Busybee::Hooks::HOOK_TYPES - around_types).each { |type| observe(type) }
    around_types.each { |type| observe_around(type) }
  end

  def observe(type)
    Busybee::Hooks.register(type, ->(carrier) { observed << [type, carrier] })
  end

  def observe_around(type)
    Busybee::Hooks.register(type, lambda { |carrier, continue|
      observed << [:"#{type}_enter", carrier]
      continue.call.tap { observed << [:"#{type}_exit", carrier] }
    })
  end

  def moments_for(carrier_class) = observed.select { |_, carrier| carrier.is_a?(carrier_class) }.map(&:first)
  def job_moments = moments_for(Busybee::Job)
  def worker_moments = moments_for(Busybee::Worker::Status)
  def call_moments = observed.select { |entry| entry.last.is_a?(Busybee::Client::Call) }
  def resolved_calls = call_moments.select { |entry| entry.first == :after_call }

  def raw_job(type:, variables:, headers:, key: rand(100_000..999_999))
    Busybee::GRPC::ActivatedJob.new(
      key: key, type: type, processInstanceKey: rand(100_000..999_999),
      bpmnProcessId: "deliver-shipment", elementId: "service-task", retries: 3,
      worker: Busybee.worker_name, deadline: (Time.now.to_i + 300) * 1000,
      variables: Busybee::Serialization.to_json(variables),
      customHeaders: Busybee::Serialization.to_json(headers)
    )
  end

  # Deliver one batch, then stop on the following poll — so the jobs are executed
  # rather than handed back, and run! exits through its ordinary teardown.
  def run_until_drained(worker_class, jobs)
    config = Busybee::RuntimeConfig.new(worker_mode: :polling)
    runner = Busybee::Runner::Polling.new(worker_class, runtime_config: config, client: gateway.client)
    deliveries = [jobs]
    gateway.on(:activate_jobs) do |_request|
      batch = deliveries.shift
      next [Busybee::GRPC::ActivateJobsResponse.new(jobs: batch)] if batch

      runner.stop!(reason: :signal)
      []
    end
    runner.run!
    runner
  end

  def run_one_distance_job(key: 5150)
    run_until_drained(Delivery::CalculateDistanceWorker, [
                        raw_job(key: key, type: "calculate_distance",
                                variables: { from_lat: 0, from_lon: 0, to_lat: 3, to_lon: 4 },
                                headers: { algorithm: "pythagorean" })
                      ])
  end

  describe "the worker lifecycle" do
    it "fires all four moments, in order, once each" do
      run_one_distance_job

      expect(worker_moments).to eq(%i[on_worker_started on_worker_stop_requested
                                      on_worker_stopping on_worker_shutdown])
    end

    it "carries a Worker::Status whose reason appears once the stop is requested" do
      run_one_distance_job

      statuses = observed.map(&:last).grep(Busybee::Worker::Status)
      expect(statuses.map(&:reason)).to eq([nil, :signal, :signal, :signal])
    end
  end

  describe "the job lifecycle" do
    it "brackets perform inside the execution chain, inside the activation bracket" do
      run_one_distance_job

      expect(job_moments).to eq(%i[on_job_activated around_job_execution_enter
                                   before_perform around_perform_enter around_perform_exit after_perform
                                   around_job_execution_exit on_job_executed])
    end

    it "hands every job moment the same Job instance" do
      run_one_distance_job(key: 6000)

      jobs = observed.filter_map { |_, carrier| carrier if carrier.is_a?(Busybee::Job) }
      expect(jobs.map(&:key).uniq).to eq([6000])
      expect(jobs.map(&:object_id).uniq.size).to eq(1)
    end

    it "reports the job already complete by the time on_job_executed fires" do
      run_one_distance_job

      _, job = observed.reverse.find { |type, _| type == :on_job_executed }
      expect(job).to be_complete
      expect(job.result).to eq("distance" => 5.0)
    end
  end

  describe "the call lifecycle" do
    it "fires call hooks for every engine call the run actually made" do
      run_one_distance_job

      expect(call_moments.map(&:first)).to eq(%i[
                                                before_call around_call_enter around_call_exit after_call
                                                before_call around_call_enter around_call_exit after_call
                                                before_call around_call_enter around_call_exit after_call
                                              ])
    end

    it "covers the fetch, the completion, and the idle poll that ends the run" do
      run_one_distance_job

      rpcs = resolved_calls.map { |_, call| call.rpc }
      expect(rpcs).to eq(%i[activate_jobs complete_job activate_jobs])
    end

    it "correlates the completion call to the job and the fetch calls to the worker only" do
      run_one_distance_job(key: 7000)

      resolved = resolved_calls.map(&:last)
      complete = resolved.find { |call| call.rpc == :complete_job }
      fetch = resolved.first

      expect(complete.job.key).to eq(7000)
      expect(complete.worker_status).to be_a(Busybee::Worker::Status)
      expect(fetch.job).to be_nil
      expect(fetch.worker_status).to be_a(Busybee::Worker::Status)
    end
  end

  describe "the demo's own monitoring bracket, driven end to end" do
    it "closes the job's row and advances the worker's row to shutdown" do
      run_one_distance_job(key: 8100)

      expect(Monitoring::JobRun.find_by(job_key: 8100)).to have_attributes(
        status: "complete", job_type: "calculate_distance", lifecycle_rank: 1
      )
      expect(Monitoring::WorkerProcess.find_by(worker_name: Busybee.worker_name,
                                               job_type: "calculate_distance")).to have_attributes(
                                                 status: "shutdown", reason: "signal", total_job_count: 1
                                               )
    end

    it "records the completion call against the job" do
      run_one_distance_job(key: 8200)

      expect(Monitoring::EngineCall.for_job(8200).pluck(:rpc)).to eq(%w[complete_job])
    end
  end
end
