# frozen_string_literal: true

require_relative "../rails_helper"

# "Does busybee call my hooks when I think it does?" — the choreography contract:
# which moments fire, in what order, carrying what. Distinct from the wiring
# question (would this hook match?) and from the hook-body question (what does the
# body do with the carrier?).
#
# Driven by execute_worker, so activation, perform, auto-completion and the
# teardown are the runner's own code and every hook level fires. No transport sits
# behind it: the calls observed are the ones the job itself makes.
RSpec.describe "Busybee hook choreography" do # rubocop:disable RSpec/DescribeClass
  let(:client) { build_test_client }
  let(:observed) { [] }

  around do |example|
    isolate_busybee_hooks do
      observe_every_moment
      example.run
    end
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

  def distance_job(key)
    build_test_job(key: key, type: "calculate_distance", bpmn_process_id: "deliver-shipment",
                   variables: { from_lat: 0, from_lon: 0, to_lat: 3, to_lon: 4 },
                   headers: { algorithm: "pythagorean" }, client: client)
  end

  def run_one_distance_job(key: 5150)
    execute_worker(Delivery::CalculateDistanceWorker, job: distance_job(key))
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
    it "fires the whole call bracket once for the one engine call the job made" do
      run_one_distance_job

      expect(call_moments.map(&:first)).to eq(%i[before_call around_call_enter around_call_exit after_call])
    end

    it "fires for the completion, the call this worker's code caused" do
      run_one_distance_job

      expect(resolved_calls.map { |_, call| call.rpc }).to eq(%i[complete_job])
      expect(client.received(:complete_job).size).to eq(1)
    end

    it "correlates the completion call to the job and to the worker running it" do
      run_one_distance_job(key: 7000)

      complete = resolved_calls.map(&:last).sole
      expect(complete.job.key).to eq(7000)
      expect(complete.worker_status).to have_attributes(worker_class: Delivery::CalculateDistanceWorker)
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

  describe "a worker held open across runs" do
    it "starts and stops once, however many runs go through it" do
      worker = start_test_worker(Delivery::CalculateDistanceWorker, client: client)
      execute_worker(worker, job: distance_job(8300))
      execute_worker(worker, job: distance_job(8301))
      worker.stop!

      expect(worker_moments).to eq(%i[on_worker_started on_worker_stop_requested
                                      on_worker_stopping on_worker_shutdown])
      expect(job_moments.count(:on_job_executed)).to eq(2)
    end

    it "keeps one row for the worker in the demo's monitoring, counting every run" do
      worker = start_test_worker(Delivery::CalculateDistanceWorker, client: client)
      execute_worker(worker, jobs: [distance_job(8400), distance_job(8401)])
      execute_worker(worker, job: distance_job(8402))
      worker.stop!

      rows = Monitoring::WorkerProcess.where(worker_name: Busybee.worker_name, job_type: "calculate_distance")
      expect(rows.pluck(:status, :total_job_count)).to eq([["shutdown", 3]])
    end
  end

  describe "a run with call hooks subtracted" do
    it "still fires every job and worker moment, and no call moment" do
      without_busybee_hooks(:call) { run_one_distance_job }

      expect(call_moments).to be_empty
      expect(job_moments).to include(:on_job_activated, :after_perform, :on_job_executed)
      expect(worker_moments).to eq(%i[on_worker_started on_worker_stop_requested
                                      on_worker_stopping on_worker_shutdown])
    end
  end
end
