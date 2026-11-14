# frozen_string_literal: true

# Formatting and chart defaults for the monitoring area: Chartkick on Chart.js
# (loaded from a CDN by the monitoring layout), styled for its dark theme.
module MonitoringHelper
  # One color per job outcome on tiles, table cells and chart marks alike.
  STATUS_COLORS = { "ready" => "#94a3b8", "complete" => "#4ade80", "failed" => "#f87171",
                    "error" => "#fbbf24", "handed_back" => "#38bdf8" }.freeze

  # Categorical series, in a fixed order checked for color-vision deficiency on a dark surface.
  SERIES_COLORS = %w[#3987e5 #d95926 #199e70 #c98500 #d55181 #008300 #9085e9 #e66767].freeze

  # Each rpc keeps its series color whatever else is on the chart.
  RPCS = %w[complete_job fail_job throw_error update_job_timeout publish_message create_process_instance
            update_job_retries deploy_resource].freeze

  CHART_DEFAULTS = { height: "220px", legend: "bottom", points: false, curve: false, thousands: ",",
                     library: { animation: false, maintainAspectRatio: false,
                                scales: { x: { ticks: { maxRotation: 0, autoSkipPadding: 24 } } } } }.freeze

  def chart(kind, data, **options) = public_send(kind, data, **CHART_DEFAULTS.deep_merge(options))

  def rpc_color(rpc) = (slot = RPCS.index(rpc.to_s)) ? SERIES_COLORS[slot] : "#898781"

  # Pins a chart's time axis to the whole range, however much of it has data.
  def time_axis(window) = { xmin: window.from.iso8601, xmax: window.to.iso8601 }

  # A time the layout's script rewrites into the browser's zone, the one the charts use.
  def local_time(time, millis: false)
    return "--" if time.nil?

    text = time.utc.strftime(millis ? "%H:%M:%S.%L UTC" : "%H:%M:%S UTC")
    tag.time(text, datetime: time.utc.iso8601(3), data: { local: millis ? "millis" : "seconds" })
  end

  def fmt_ms(millis) = millis.nil? ? "--" : "#{number_with_delimiter(millis.round(1))} ms"
  def fmt_pct(pct) = pct.nil? ? "--" : "#{pct.round(1)}%"
  def fmt_int(count) = count.nil? ? "--" : number_with_delimiter(count)
end
