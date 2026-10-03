# frozen_string_literal: true

require_relative "../rails_helper"

# "When this carrier reaches this moment, what does our hook code do?" — asked of
# the demo's own registrations in config/initializers/busybee.rb by firing each
# moment with fire_hooks. A filter with valid vocabulary and a wrong value is
# silently inert forever, and here it shows up as a missing effect: the three
# transactional around_perform hooks name four literal job types, in a file far
# from the workers that derive them.
RSpec.describe "Busybee hook wiring" do # rubocop:disable RSpec/DescribeClass
  def domain_records = [Oms::Record, Logistics::Record, Delivery::Record]

  # Every worker the app actually defines, so a newly-added one cannot slip past
  # the claims below by simply not being listed here.
  def workers
    Rails.application.eager_load!
    Busybee::Worker.descendants.sort_by(&:name)
  end

  def job_for(worker_class, **)
    build_test_job(type: worker_class.job_type, bpmn_process_id: "ship-order", worker_class: worker_class, **)
  end

  # Domain transactions open around perform, by domain.
  def transactions_around_perform(worker_class)
    baseline = domain_records.to_h { |record| [record, record.connection.open_transactions] }
    opened = {}
    fire_hooks(:around_perform, job_for(worker_class)) do
      domain_records.each do |record|
        depth = record.connection.open_transactions - baseline[record]
        opened[record] = depth if depth.positive?
      end
    end
    opened
  end

  # Outside the example's own transaction, which a domain transaction would only
  # join. Nothing here writes.
  describe "the transactional around_perform hooks", :no_transaction do
    it "wrap exactly the four transactional job types, each in one domain transaction" do
      transacted = workers.to_h { |worker| [worker.job_type, transactions_around_perform(worker)] }.
                   reject { |_, opened| opened.empty? }

      expect(transacted.keys).to match_array(%w[update_order_status create_shipment update_shipment_status
                                                assign_driver])
      expect(transacted.values.map(&:values)).to all(eq([1]))
    end

    it "leave every other job untransacted, complete_driver_delivery included" do
      delivery = workers.find { |worker| worker.job_type == "complete_driver_delivery" }

      expect(transactions_around_perform(delivery)).to be_empty
    end
  end

  describe "the rollover hazard" do
    # Disabled under test so it can't randomly fail unrelated specs; enabled here,
    # with the roll forced, to see what it does to each worker's jobs.
    around do |example|
      previous = Rails.application.config.x.demo.rollovers_enabled
      Rails.application.config.x.demo.rollovers_enabled = true
      example.run
    ensure
      Rails.application.config.x.demo.rollovers_enabled = previous
    end

    before { allow(Sim::RolloverPolicy).to receive(:roll).and_return(0.5) }

    def rolls_over?(worker_class)
      fire_hooks(:around_perform, job_for(worker_class))
      false
    rescue Sim::Rollover
      true
    end

    it "rolls every business worker over and spares the sim workers" do
      rolled, spared = workers.partition { |worker| rolls_over?(worker) }

      expect(rolled.map(&:name)).to all(satisfy { |name| !name.start_with?("Sim::") })
      expect(spared.map(&:name)).to contain_exactly("Sim::DeliveryRunWorker", "Sim::PickAndPackWorker")
    end
  end

  describe "the monitoring bracket" do
    it "opens a job's run on activation and closes it on execution" do
      job = job_for(Delivery::CalculateDistanceWorker, key: 6100, status: :complete)

      fire_hooks(:on_job_activated, job)
      expect(Monitoring::JobRun.find_by(job_key: 6100)).to have_attributes(lifecycle_rank: 0)

      fire_hooks(:on_job_executed, job)
      expect(Monitoring::JobRun.find_by(job_key: 6100)).to have_attributes(lifecycle_rank: 1, status: "complete")
    end

    it "closes a handed-back job's run too, so the bracket always closes" do
      job = job_for(Delivery::CalculateDistanceWorker, key: 6200)

      fire_hooks(:on_job_activated, job)
      fire_hooks(:on_job_not_executed, job)

      expect(Monitoring::JobRun.find_by(job_key: 6200)).to have_attributes(lifecycle_rank: 1, status: "ready")
    end

    it "advances the worker's row through all four moments" do
      worker = start_test_worker(Delivery::CalculateDistanceWorker)
      row = -> { Monitoring::WorkerProcess.find_by(worker_name: Busybee.worker_name, job_type: "calculate_distance") }

      phases = %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown].map do |moment|
        fire_hooks(moment, worker)
        row.call.status
      end

      expect(phases).to eq(%w[running stop_requested stopping shutdown])
    end

    it "records each call against the job it was made for" do
      job = job_for(Delivery::CalculateDistanceWorker, key: 6300)

      fire_hooks(:after_call, build_test_call(:complete_job, job: job))

      expect(Monitoring::EngineCall.for_job(6300).pluck(:rpc)).to eq(%w[complete_job])
    end

    # Nothing is registered at the gating moments, which leaves nothing to fire.
    it "observes calls after the fact rather than gating them" do
      expect(Busybee::Hooks.hooks_for(:before_call)).to be_empty
      expect(Busybee::Hooks.hooks_for(:around_call)).to be_empty
    end
  end
end
