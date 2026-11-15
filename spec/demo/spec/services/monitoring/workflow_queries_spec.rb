# frozen_string_literal: true

require_relative "../../rails_helper"

RSpec.describe "Workflow queries" do # rubocop:disable RSpec/DescribeClass
  let(:now) { Time.current }
  let(:window) { Monitoring::Window.new("1h", now: now) }
  let(:job_keys) { (1..).each }

  def run!(job_type, workflow, total: 10, **attrs)
    Monitoring::JobRun.create!(job_key: job_keys.next, activated_at: now - 1.minute, job_type: job_type,
                               status: "complete", bpmn_process_id: workflow, total_duration_ms: total, **attrs)
  end

  describe Monitoring::WorkflowShare do
    it "splits each job type's jobs across the workflows they ran in, busiest type first" do
      3.times { run!("update_order_status", "ship_order") }
      2.times { run!("update_order_status", "prepare_order") }
      run!("plan_shipments", "prepare_order")
      run!("plan_shipments", "prepare_order", activated_at: now - 2.hours)

      rows = described_class.new(Monitoring::JobRun.all, window).rows

      expect(rows).to eq([
                           { job_type: "update_order_status", jobs: 5,
                             shares: [{ workflow: "ship_order", jobs: 3, pct: 60.0 },
                                      { workflow: "prepare_order", jobs: 2, pct: 40.0 }] },
                           { job_type: "plan_shipments", jobs: 1,
                             shares: [{ workflow: "prepare_order", jobs: 1, pct: 100.0 }] }
                         ])
    end
  end

  describe Monitoring::ElementLatency do
    it "takes p95 total time per element of each workflow, slowest first, over resolved runs" do
      [10, 20, 30, 40, 1000].each { |ms| run!("pick", "ship_order", total: ms, element_id: "pick-task") }
      run!("pick", "ship_order", total: 99_999, status: "handed_back", element_id: "pick-task")
      run!("ship", "ship_order", total: 5, element_id: "ship-task")

      rows = described_class.new(Monitoring::JobRun.all, window).rows

      expect(rows.map { |row| row.values_at(:element_id, :job_type, :jobs, :p95_ms) }).
        to eq([["pick-task", "pick", 5, 808.0], ["ship-task", "ship", 1, 5.0]])
    end
  end

  describe Monitoring::SlowInstances do
    it "ranks instances by their jobs' total time against their workflow's median instance" do
      run!("a", "ship_order", total: 100, process_instance_key: 1)
      run!("b", "ship_order", total: 100, process_instance_key: 1) # 200
      run!("a", "ship_order", total: 150, process_instance_key: 2) # 150
      run!("a", "ship_order", total: 900, process_instance_key: 3) # 900
      run!("a", "prepare_order", total: 50, process_instance_key: 4) # its own workflow's median
      run!("a", "ship_order", total: 5_000, status: "ready", process_instance_key: 2) # unresolved: no job time yet

      rows = described_class.new(Monitoring::JobRun.all, window).rows

      expect(rows.map { |row| row.values_at(:instance_key, :workflow, :jobs, :job_ms, :median_ms, :ratio) }).
        to eq([[3, "ship_order", 1, 900.0, 200.0, 4.5], [1, "ship_order", 2, 200.0, 200.0, 1.0],
               [4, "prepare_order", 1, 50.0, 50.0, 1.0], [2, "ship_order", 1, 150.0, 200.0, 0.75]])
    end
  end
end
