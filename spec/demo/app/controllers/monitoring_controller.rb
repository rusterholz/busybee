# frozen_string_literal: true

# The operational view: what busybee is doing, as distinct from what the
# business is doing. Rendered in dark mode via its own layout. Filters are
# carried in the query string so they survive the page's auto-refresh.
class MonitoringController < ApplicationController
  layout "monitoring"

  RECENT_LIMIT = 100

  def index
    @job_types = filter_options(:job_type)
    @processes = filter_options(:bpmn_process_id)
    read_filters
    scope = filtered(Monitoring::JobRun.all)
    @stats = Monitoring::Stats.new(scope)
    @runs = scope.recent.limit(RECENT_LIMIT)
  end

  private

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
end
