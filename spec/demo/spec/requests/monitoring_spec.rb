# frozen_string_literal: true

require_relative "../rails_helper"
require "rack/test"

RSpec.describe "Monitoring control center" do # rubocop:disable RSpec/DescribeClass
  include Rack::Test::Methods

  def app = Rails.application

  it "renders on an empty database" do
    get "/monitoring"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("What busybee is doing")
    expect(last_response.body).to include("No workers have reported yet")
  end

  it "renders workers, engine calls and a per-job call sequence" do
    Monitoring::JobRun.create!(job_key: 476, job_type: "update_order_status", status: "complete",
                               perform_duration_ms: 12.0, total_duration_ms: 30.0)
    Monitoring::WorkerProcess.create!(worker_name: "oms-worker-ab12", job_type: "update_order_status",
                                      status: "shutdown", reason: "rollover", total_job_count: 9,
                                      write_queue_depth: 2, started_at: 30.seconds.ago)
    Monitoring::CallMetric.observe("engine_call",
                                   { rpc: "complete_job", worker_class: "Oms::UpdateOrderStatusWorker" }, 117.0)
    Monitoring::EngineCall.create!(job_key: 476, worker_name: "oms-worker-ab12", rpc: "complete_job",
                                   status: "succeeded", network_ms: 117.0, seq: 1.0)

    get "/monitoring"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("oms-worker-ab12")    # incarnation graveyard
    expect(last_response.body).to include("rollover")           # stop-reason badge
    expect(last_response.body).to include("complete_job")       # engine-call rollup + the call pill
    expect(last_response.body).to include("update_order_status") # jobs-by-type
  end
end
