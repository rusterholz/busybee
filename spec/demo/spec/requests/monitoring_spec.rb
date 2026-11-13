# frozen_string_literal: true

require_relative "../rails_helper"
require "rack/test"

RSpec.describe "Monitoring" do
  include Rack::Test::Methods

  def app = Rails.application
  def body = last_response.body

  def run!(job_key, job_type: "update_order_status", status: "complete", at: Time.current, **attrs)
    Monitoring::JobRun.create!(job_key: job_key, activated_at: at, job_type: job_type, status: status, **attrs)
  end

  def worker!(name, worker_class, status: "running", job_type: "t")
    Monitoring::WorkerProcess.create!(worker_name: name, worker_class: worker_class,
                                      job_type: job_type, status: status)
  end

  describe "navigation" do
    it "sends /monitoring to the Workers page, keeping its query" do
      get "/monitoring?range=6h&job_type=pick"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/monitoring/workers?job_type=pick&range=6h")
    end

    it "carries the range and filters on every tab, and nothing page-local" do
      get "/monitoring/workers?range=15m&workflow=ship_order&failed=1"

      expect(body).to include('href="/monitoring/workflows?range=15m&amp;workflow=ship_order"',
                              'href="/monitoring/infrastructure?range=15m&amp;workflow=ship_order"')
    end

    it "offers the three ranges, marking the current one" do
      get "/monitoring/workers?range=6h"

      expect(body).to include("/monitoring/workers?range=15m", "/monitoring/workers?range=1h")
      expect(body).to match(%r{<a [^>]*aria-current="true"[^>]*>6h</a>})
    end
  end

  describe "Workers page" do
    it "renders on an empty database" do
      get "/monitoring/workers"

      expect(last_response.status).to eq(200)
      expect(body).to include("No job runs in this range")
    end

    it "counts runs by status, handed_back included" do
      run!(1, status: "handed_back")
      run!(2, status: "complete")

      get "/monitoring/workers"

      expect(body).to match(%r{<h2 class="status-handed_back">1</h2>\s*<small>handed_back</small>})
    end

    it "summarizes each job type, linking to its filter, and names the failure-rate definition" do
      run!(1, job_type: "plan_shipments", status: "failed", total_duration_ms: 50.0)
      run!(2, job_type: "plan_shipments", status: "complete", total_duration_ms: 10.0)

      get "/monitoring/workers"

      expect(body).to include('href="/monitoring/workers?job_type=plan_shipments"', "50.0%")
      expect(body).to include("failed ÷ (complete + failed + error)")
    end

    it "draws the throughput, latency and failure-rate charts" do
      run!(1)

      get "/monitoring/workers"

      expect(body.scan("new Chartkick").size).to eq(3)
    end

    it "scopes everything to the job type, workflow and range" do
      run!(1, job_type: "type_a", bpmn_process_id: "ship_order", error_message: "errmsg-a")
      run!(2, job_type: "type_b", bpmn_process_id: "ship_order", error_message: "errmsg-b")
      run!(3, job_type: "type_a", bpmn_process_id: "prepare_order", error_message: "errmsg-c")
      run!(4, job_type: "type_a", bpmn_process_id: "ship_order", error_message: "errmsg-d", at: 2.hours.ago)

      get "/monitoring/workers?job_type=type_a&workflow=ship_order"

      expect(body).to include("errmsg-a")
      expect(body).not_to include("errmsg-b", "errmsg-c", "errmsg-d")
    end

    it "shows the ten newest runs, each linked to its detail page and unfolding its calls" do
      12.times { |i| run!(i, status: "failed", error_message: format("errmsg-%02d", i), at: (12 - i).minutes.ago) }
      Monitoring::EngineCall.create!(job_key: 11, worker_name: "w", rpc: "fail_job", status: "succeeded",
                                     network_ms: 4.0, seq: 1.0, at: Time.current)

      get "/monitoring/workers"

      expect(body).to include("errmsg-11", "/monitoring/runs/11", "fail_job")
      expect(body).not_to include("errmsg-01")
    end

    it "narrows recent runs to failed ones with the local toggle" do
      run!(1, status: "failed", error_message: "boom-failed")
      run!(2, status: "complete", error_message: "quiet-complete")

      get "/monitoring/workers?failed=1"

      expect(body).to include("boom-failed")
      expect(body).not_to include("quiet-complete")
    end
  end

  describe "Infrastructure page" do
    it "shows running workers by default; worker_status=all reveals the stopped ones" do
      worker!("oms-worker-live1", "Oms::UpdateOrderStatusWorker")
      worker!("oms-worker-dead1", "Oms::UpdateOrderStatusWorker", status: "shutdown")

      get "/monitoring/infrastructure"
      expect(body).to include("oms-worker-live1")
      expect(body).not_to include("oms-worker-dead1")

      get "/monitoring/infrastructure?worker_status=all"
      expect(body).to include("oms-worker-dead1")
    end

    # A streaming worker with no work makes no calls, so it writes nothing for as
    # long as it idles; its last lifecycle event still says running.
    it "reads an idle worker as running, with its idle time as information only" do
      worker!("oms-worker-idle", "Oms::UpdateOrderStatusWorker").update_column(:updated_at, 10.minutes.ago)
      Monitoring::EngineCall.create!(worker_name: "oms-worker-idle", rpc: "activate_jobs", seq: 1.0,
                                     at: 10.minutes.ago)

      get "/monitoring/infrastructure"

      expect(body).to include("oms-worker-idle", "idle 10m")
      expect(body).to include('class="dot dot-fresh"', "<b>1</b> running")
    end
  end

  describe "detail pages" do
    it "renders a worker incarnation's full detail" do
      w = worker!("oms-worker-deet1", "Oms::UpdateOrderStatusWorker", job_type: "update_order_status")
      w.update!(total_job_count: 9, peak_buffer_size: 3, started_at: 5.minutes.ago,
                error_class: "RuntimeError", error_message: "full error text here")
      Monitoring::EngineCall.create!(job_key: 900, worker_name: "oms-worker-deet1", rpc: "activate_jobs",
                                     status: "succeeded", network_ms: 12.0, seq: 1.0, at: Time.current)

      get "/monitoring/workers/#{w.id}"

      expect(last_response.status).to eq(200)
      expect(body).to include("oms-worker-deet1", "Oms::UpdateOrderStatusWorker",
                              "full error text here", "activate_jobs")
    end

    it "redirects to the dashboard for an unknown worker id" do
      get "/monitoring/workers/nope"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to include("/monitoring")
    end

    it "renders a run's full detail with its tags and call sequence" do
      run!(901, job_type: "plan_shipments", perform_duration_ms: 12.5, total_duration_ms: 30.0,
                tags: { "element_id" => "plan-shipments-task", "retries" => 3 })
      Monitoring::EngineCall.create!(job_key: 901, worker_name: "logistics-worker-x", rpc: "complete_job",
                                     status: "succeeded", network_ms: 7.5, seq: 2.0, at: Time.current)

      get "/monitoring/runs/901"

      expect(last_response.status).to eq(200)
      expect(body).to include("plan_shipments", "plan-shipments-task", "complete_job", "logistics-worker-x")
    end
  end
end
