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

  it "keeps the top tiles to the job lifecycle (calls live in their own section)" do
    get "/monitoring"

    expect(last_response.body).not_to include("buffered") # provenance, not lifecycle
    expect(last_response.body).to include("calls / job")
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

    get "/monitoring?worker_status=all"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("oms-worker-ab12")    # incarnation graveyard
    expect(last_response.body).to include("rollover")           # stop-reason badge
    expect(last_response.body).to include("complete_job")       # engine-call rollup + the call pill
    expect(last_response.body).to include("update_order_status") # jobs-by-type
  end

  def worker!(name, worker_class, status: "running", job_type: "t")
    Monitoring::WorkerProcess.create!(worker_name: name, worker_class: worker_class,
                                      job_type: job_type, status: status)
  end

  it "shows only running workers by default; worker_status=all reveals the graveyard" do
    worker!("oms-worker-live1", "Oms::UpdateOrderStatusWorker")
    worker!("oms-worker-dead1", "Oms::UpdateOrderStatusWorker", status: "shutdown")

    get "/monitoring"
    expect(last_response.body).to include("oms-worker-live1")
    expect(last_response.body).not_to include("oms-worker-dead1")

    get "/monitoring?worker_status=all"
    expect(last_response.body).to include("oms-worker-dead1")
  end

  it "filters workers by domain (worker_class namespace)" do
    worker!("oms-worker-a", "Oms::UpdateOrderStatusWorker")
    worker!("logistics-worker-b", "Logistics::PlanShipmentsWorker")

    get "/monitoring?worker_domain=logistics"

    expect(last_response.body).to include("logistics-worker-b")
    expect(last_response.body).not_to include("oms-worker-a")
  end

  it "filters the job sections by domain via the observed worker classes" do
    # Shutdown workers stay out of the (running-filtered) worker table but
    # still feed the domain map — the job sections are what's under test.
    worker!("oms-worker-a", "Oms::AWorker", job_type: "type_a", status: "shutdown")
    worker!("logistics-worker-b", "Logistics::BWorker", job_type: "type_b", status: "shutdown")
    Monitoring::JobRun.create!(job_key: 1, job_type: "type_a", status: "complete")
    Monitoring::JobRun.create!(job_key: 2, job_type: "type_b", status: "complete")

    get "/monitoring?domain=oms"

    expect(last_response.body).to include("<code>type_a</code>")
    expect(last_response.body).not_to include("<code>type_b</code>")
  end

  it "caps recent runs at the ten newest" do
    12.times do |i|
      Monitoring::JobRun.create!(job_key: i, job_type: "t", status: "failed",
                                 error_message: format("errmsg-%02d", i),
                                 activated_at: (12 - i).minutes.ago)
    end

    get "/monitoring"

    expect(last_response.body).to include("errmsg-11") # newest
    expect(last_response.body).not_to include("errmsg-01")
  end
end
