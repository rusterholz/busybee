# frozen_string_literal: true

# All of the demo app's busybee hook configuration in one Busybee.configure
# block — the way you'd typically wire busybee into a brownfield application.
# (Connection settings live separately, in config/application.rb.)
Busybee.configure do |config|
  # Observability: record every job run into Monitoring::JobRun — the demo's
  # stand-in for a Datadog/OTel sink. These hooks are fired by the runner with
  # safe: true (a failure can't disrupt job execution), and the recorder offloads
  # the write to a background thread so it never blocks the runner.
  config.on_job_activated { |job| Monitoring::Recorder.record_activation(job) }
  config.on_job_executed  { |job| Monitoring::Recorder.record_execution(job) }

  # Per-job transactions: wrap the listed jobs' perform in a transaction on their
  # domain's database, so their writes commit atomically and these jobs no longer
  # open transactions themselves. Registered per job type (the array filter covers
  # logistics' two in one go). Deliberately NOT applied to: the async sim jobs
  # (perform returns before the work runs, so a transaction would wrap nothing)
  # and complete_driver_delivery (publishes a Zeebe message a transaction can't
  # roll back).
  config.around_job(job_type: "update_order_status") do |_job, perform|
    Oms::Record.transaction { perform.call }
  end

  config.around_job(job_type: %w[create_shipment update_shipment_status]) do |_job, perform|
    Logistics::Record.transaction { perform.call }
  end

  config.around_job(job_type: "assign_driver") do |_job, perform|
    Delivery::Record.transaction { perform.call }
  end
end
