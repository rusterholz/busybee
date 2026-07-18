# frozen_string_literal: true

# The operational view: what busybee is doing, as distinct from what the
# business is doing. Rendered in dark mode via its own layout. Filters are
# carried in the query string so they survive the page's auto-refresh — the
# job filter scopes the job-centric sections, the worker filter scopes the
# worker table (live incarnations by default), and each section's form
# carries the other's params as hidden fields so they compose.
class MonitoringController < ApplicationController
  layout "monitoring"

  RECENT_LIMIT = 10

  def index
    read_job_filters
    read_worker_filters
    @job_types = filter_options(:job_type)
    @processes = filter_options(:bpmn_process_id)
    @domains = domain_map.keys.sort
    @worker_types = Monitoring::WorkerProcess.where.not(job_type: nil).distinct.order(:job_type).pluck(:job_type)
    load_jobs
    load_platform
  end

  private

  # Job-centric sections, scoped by the active filter.
  def load_jobs
    scope = filtered(Monitoring::JobRun.all)
    @stats = Monitoring::Stats.new(scope)
    @runs = scope.recent.limit(RECENT_LIMIT).to_a
    @calls_by_job = engine_calls_for(@runs)
  end

  # Whole-platform sections (engine calls, liveness); the worker table has its
  # own filter, defaulting to the live incarnations.
  def load_platform
    @workers = filtered_workers(Monitoring::WorkerProcess.recent)
    @workers_exist = Monitoring::WorkerProcess.exists?
    @call_stats = Monitoring::CallStats.new
    @calls_per_job = @call_stats.calls_per_job(Monitoring::JobRun.count)
    @liveness = Monitoring::Liveness.new
  end

  def read_job_filters
    @selected_types = Array(params[:job_types]).reject(&:blank?)
    @selected_status = params[:status].presence
    @selected_process = params[:process].presence
    @selected_domain = params[:domain].presence
  end

  def read_worker_filters
    @worker_status = params[:worker_status].presence || "running"
    @worker_domain = params[:worker_domain].presence
    @worker_type = params[:worker_type].presence
  end

  def filter_options(column)
    Monitoring::JobRun.where.not(column => nil).distinct.order(column).pluck(column)
  end

  def filtered(scope)
    scope = scope.where(job_type: @selected_types) if @selected_types.any?
    scope = scope.where(status: @selected_status) if @selected_status
    scope = scope.where(bpmn_process_id: @selected_process) if @selected_process
    scope = scope.where(job_type: domain_types(@selected_domain)) if @selected_domain
    scope
  end

  def filtered_workers(scope)
    scope = scope.where(status: @worker_status) unless @worker_status == "all"
    scope = scope.where(worker_class: domain_classes(@worker_domain)) if @worker_domain
    scope = scope.where(job_type: @worker_type) if @worker_type
    scope
  end

  # domain (worker_class namespace, downcased) → observed [worker_class,
  # job_type] pairs — how "domain" resolves without a schema column for it.
  def domain_map
    @domain_map ||= Monitoring::WorkerProcess.distinct.pluck(:worker_class, :job_type).
                    reject { |worker_class, _| worker_class.nil? }.
                    group_by { |worker_class, _| worker_class.split("::").first.downcase }
  end

  def domain_classes(domain) = domain_map.fetch(domain, []).map(&:first).uniq
  def domain_types(domain) = domain_map.fetch(domain, []).map(&:last).uniq

  # The per-job call sequences for the runs on screen, keyed by job_key so each
  # row can unfold its calls without an N+1.
  def engine_calls_for(runs)
    Monitoring::EngineCall.where(job_key: runs.map(&:job_key)).order(:seq).group_by(&:job_key)
  end
end
