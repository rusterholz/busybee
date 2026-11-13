# frozen_string_literal: true

# The operational view: what busybee is doing, as distinct from what the
# business is doing, in one page per operator audience (workers, workflows,
# infrastructure) plus run and worker detail pages. Rendered in dark mode via
# its own layout. The range and the job-type and workflow filters ride the query
# string, so they survive the page's auto-refresh and carry across the tabs;
# page-local toggles (failed runs only, worker phase) stay on their own page.
class MonitoringController < ApplicationController
  layout "monitoring"

  RECENT_LIMIT = 10
  FILTERS = %w[range job_type workflow].freeze

  before_action :read_filters, :load_liveness, except: :index
  before_action :drop_complete_selection, except: :index
  helper_method :filter_params

  def index = redirect_to(monitoring_workers_path(request.query_parameters))

  def workers
    @stats = Monitoring::Stats.new(job_scope.within(@window))
    @trends = Monitoring::JobTrends.new(job_scope, @window)
    @job_type_rows = Monitoring::JobTypeSummary.new(job_scope, @window).rows
    @failed_only = params[:failed].present?
    @runs = recent_runs
    @calls_by_job = engine_calls_for(@runs)
  end

  def workflows; end

  def infrastructure
    @worker_status = params[:worker_status].presence || "running"
    workers = Monitoring::WorkerProcess.recent
    workers = workers.where(status: @worker_status) unless @worker_status == "all"
    @workers = workers.to_a
    @workers_exist = Monitoring::WorkerProcess.exists?
    @last_calls = @liveness.last_call_at(@workers.map(&:worker_name))
    @call_stats = Monitoring::CallStats.new
  end

  # One incarnation's full detail: everything the index line compresses, plus
  # its recent engine calls (worker_name is per-boot unique, so the call log is
  # the incarnation's own).
  def worker
    @worker = Monitoring::WorkerProcess.find(params[:id])
    @calls = Monitoring::EngineCall.where(worker_name: @worker.worker_name).order(seq: :desc).limit(50)
  rescue ActiveRecord::RecordNotFound
    redirect_to monitoring_path
  end

  # One run's full detail: timings, the full tag set, and its call sequence,
  # with each call linked back to the incarnation that made it.
  def run
    @run = Monitoring::JobRun.where(job_key: params[:job_key]).recent.first!
    @calls = Monitoring::EngineCall.for_job(@run.job_key)
    @call_workers = Monitoring::WorkerProcess.where(worker_name: @calls.map(&:worker_name).uniq,
                                                    job_type: @run.job_type).index_by(&:worker_name)
  rescue ActiveRecord::RecordNotFound
    redirect_to monitoring_path
  end

  private

  # The cross-page selection, as the query a tab or range link carries.
  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTERS).merge(overrides.stringify_keys).compact_blank
  end

  def read_filters
    @window = Monitoring::Window.new(params[:range])
    @job_types = filter_options(:job_type)
    @selected_types = Array(params[:job_type]).compact_blank
    @workflow = params[:workflow].presence
    @workflows = filter_options(:bpmn_process_id)
  end

  # Every job type selected is the same as none: all of them, at the clean URL.
  def drop_complete_selection
    return if @selected_types.empty? || @job_types.empty? || (@job_types - @selected_types).any?

    redirect_to url_for(request.query_parameters.except("job_type"))
  end

  def filter_options(column)
    Monitoring::JobRun.where.not(column => nil).distinct.order(column).pluck(column)
  end

  def recent_runs
    runs = job_scope.within(@window)
    runs = runs.where(status: "failed") if @failed_only
    runs.recent.limit(RECENT_LIMIT).to_a
  end

  def load_liveness = @liveness = Monitoring::Liveness.new

  def job_scope
    scope = Monitoring::JobRun.all
    scope = scope.where(job_type: @selected_types) if @selected_types.any?
    scope = scope.where(bpmn_process_id: @workflow) if @workflow
    scope
  end

  # The per-job call sequences for the runs on screen, keyed by job_key so each
  # row can unfold its calls without an N+1.
  def engine_calls_for(runs)
    Monitoring::EngineCall.where(job_key: runs.map(&:job_key)).order(:seq).group_by(&:job_key)
  end
end
