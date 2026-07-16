# frozen_string_literal: true

# The operational view: what busybee is doing, as distinct from what the
# business is doing. Rendered in dark mode via its own layout. Filters are
# carried in the query string so they survive the page's auto-refresh. The job
# filter scopes the job-centric sections; the worker and engine-call sections
# are global (the whole platform's health at a glance).
class MonitoringController < ApplicationController
  layout "monitoring"

  RECENT_LIMIT = 100

  def index
    read_filters
    @job_types = filter_options(:job_type)
    @processes = filter_options(:bpmn_process_id)
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

  # Whole-platform sections (workers, engine calls, liveness), unfiltered.
  def load_platform
    @workers = Monitoring::WorkerProcess.recent
    @call_stats = Monitoring::CallStats.new
    @calls_per_job = @call_stats.calls_per_job(Monitoring::JobRun.count)
    @liveness = Monitoring::Liveness.new
  end

  def read_filters
    @selected_types = Array(params[:job_types]).reject(&:blank?)
    @selected_status = params[:status].presence
    @selected_process = params[:process].presence
  end

  def filter_options(column)
    Monitoring::JobRun.where.not(column => nil).distinct.order(column).pluck(column)
  end

  def filtered(scope)
    scope = scope.where(job_type: @selected_types) if @selected_types.any?
    scope = scope.where(status: @selected_status) if @selected_status
    scope = scope.where(bpmn_process_id: @selected_process) if @selected_process
    scope
  end

  # The per-job call sequences for the runs on screen, keyed by job_key so each
  # row can unfold its calls without an N+1.
  def engine_calls_for(runs)
    Monitoring::EngineCall.where(job_key: runs.map(&:job_key)).order(:seq).group_by(&:job_key)
  end
end
