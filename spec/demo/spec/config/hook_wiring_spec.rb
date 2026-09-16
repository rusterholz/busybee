# frozen_string_literal: true

require_relative "../rails_helper"

# "Would this hook even fire for this job?" — asked of the demo's own registrations
# in config/initializers/busybee.rb. Nothing executes here; this is pure matching,
# which is what makes it a different question from "what does the hook body do".
#
# It earns its keep because a filter with valid vocabulary and a wrong value is
# silently inert forever. The three transactional around_perform hooks name four
# literal job types in a file far from the workers that derive them — nothing
# declares those strings — and the initializer makes a negative claim in a comment
# ("Not the async sim jobs ... nor complete_driver_delivery") that nothing checked.
RSpec.describe "Busybee hook wiring" do # rubocop:disable RSpec/DescribeClass
  # Every worker the app actually defines, so a newly-added one cannot slip past
  # the claims below by simply not being listed here.
  def workers
    Rails.application.eager_load!
    Busybee::Worker.descendants.sort_by(&:name)
  end

  def worker_for(job_type) = workers.find { |worker| worker.job_type == job_type }

  def job_for(worker_class)
    build_demo_job(type: worker_class.job_type, bpmn_process_id: "ship-order", worker_class: worker_class)
  end

  def matching(type, target)
    Busybee::Hooks.hooks_for(type).select { |hook| Busybee::Hooks.matches?(hook, target) }
  end

  def filtered(hooks) = hooks.select { |hook| hook[:filters].any? }
  def unfiltered(hooks) = hooks.reject { |hook| hook[:filters].any? }

  # Read the wiring rather than restating it: whatever job types the initializer
  # actually filtered on, in whichever registration.
  def transactional_types
    filtered(Busybee::Hooks.hooks_for(:around_perform)).flat_map { |hook| Array(hook[:filters][:job_type]) }
  end

  describe "the transactional around_perform hooks" do
    it "filters on job types that real workers actually declare" do
      expect(transactional_types).to match_array(%w[update_order_status create_shipment
                                                    update_shipment_status assign_driver])
      expect(workers.map(&:job_type)).to include(*transactional_types)
    end

    it "wraps each transactional job in exactly one domain transaction" do
      transactional_types.each do |job_type|
        hooks = filtered(matching(:around_perform, job_for(worker_for(job_type))))

        expect(hooks.size).to eq(1), "expected exactly one transaction hook for #{job_type}, got #{hooks.size}"
      end
    end

    it "leaves every other job untransacted, complete_driver_delivery included" do
      untransacted = workers.reject { |worker| transactional_types.include?(worker.job_type) }

      expect(untransacted.map(&:job_type)).to include("complete_driver_delivery")
      untransacted.each do |worker|
        expect(filtered(matching(:around_perform, job_for(worker)))).to be_empty,
                                                                        "#{worker.job_type} matched a transaction hook"
      end
    end
  end

  describe "the rollover hazard" do
    # Registered without filters, so it *matches* every job — including the sim
    # workers it exempts. That exemption lives in the hook's body, not in its
    # wiring, which is precisely why "would it fire?" and "what does it do?" are
    # two questions: this hook fires for Sim::PickAndPackWorker and does nothing.
    it "matches every job, sim workers included" do
      workers.each do |worker|
        hazards = unfiltered(matching(:around_perform, job_for(worker)))

        expect(hazards).not_to be_empty, "#{worker.job_type} matched no hazard hook"
      end
    end
  end

  describe "the monitoring bracket" do
    # Exactly one of the two closers fires per activation, so the bracket always
    # closes. Unfiltered by design — monitoring that skipped a job type would be
    # worse than none.
    it "registers an unfiltered hook at every job-lifecycle moment it brackets" do
      %i[on_job_activated on_job_executed on_job_not_executed].each do |type|
        expect(unfiltered(Busybee::Hooks.hooks_for(type))).not_to be_empty, "no unfiltered #{type} hook"
      end
    end

    it "registers an unfiltered hook at all four worker-lifecycle moments" do
      %i[on_worker_started on_worker_stop_requested on_worker_stopping on_worker_shutdown].each do |type|
        expect(unfiltered(Busybee::Hooks.hooks_for(type))).not_to be_empty, "no unfiltered #{type} hook"
      end
    end

    it "observes calls after the fact rather than gating them" do
      expect(Busybee::Hooks.hooks_for(:after_call)).not_to be_empty
      expect(Busybee::Hooks.hooks_for(:before_call)).to be_empty
      expect(Busybee::Hooks.hooks_for(:around_call)).to be_empty
    end
  end
end
