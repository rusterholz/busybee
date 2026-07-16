# frozen_string_literal: true

# All of the demo's busybee hook wiring in one Busybee.configure block — how you'd
# wire it into a brownfield app. (Connection config lives in application.rb.)
Busybee.configure do |config|
  # Record each job run into Monitoring::JobRun — the demo's Datadog/OTel stand-in.
  config.on_job_activated { |job| Monitoring::Recorder.record_activation(job) }
  config.on_job_executed  { |job| Monitoring::Recorder.record_execution(job) }

  # Upsert each worker's phase into Monitoring::WorkerProcess as its run progresses.
  config.on_worker_started        { |worker| Monitoring::Recorder.record_worker(:running, worker) }
  config.on_worker_stop_requested { |worker| Monitoring::Recorder.record_worker(:stop_requested, worker) }
  config.on_worker_stopping       { |worker| Monitoring::Recorder.record_worker(:stopping, worker) }
  config.on_worker_shutdown       { |worker| Monitoring::Recorder.record_worker(:shutdown, worker) }

  # Fold every gRPC call into the engine_call aggregate.
  config.after_call { |call| Monitoring::Recorder.record_call(call) }
  # ...and refresh the worker's row from each call — keeps counters live, even for idle workers that only fetch.
  config.after_call { |call| Monitoring::Recorder.record_worker(:running, call.worker_status) if call.worker_status }

  # Wrap these jobs' perform in a domain transaction. Not the async sim jobs (perform
  # returns before the work runs) nor complete_driver_delivery (publishes a message a
  # transaction can't undo).
  config.around_job(job_type: "update_order_status") do |_job, perform|
    Oms::Record.transaction { perform.call }
  end

  config.around_job(job_type: %w[create_shipment update_shipment_status]) do |_job, perform|
    Logistics::Record.transaction { perform.call }
  end

  config.around_job(job_type: "assign_driver") do |_job, perform|
    Delivery::Record.transaction { perform.call }
  end

  # Simulated rollovers: recycle the business workers like a k8s rollout. A per-job
  # hazard (rising with uptime × sim speed) raises Sim::Rollover — a declared
  # shutdown error → graceful :unhealthy shutdown; restart: unless-stopped (compose)
  # then returns the container as a fresh incarnation. Sim's async workers are exempt.
  config.around_job do |job, perform|
    # Rolling *before* perform (not from on_job_executed) also fails the pending job —
    # so this one hook simulates two production behaviours at once: a rollout, and an
    # ordinary transient job failure that the engine's retry budget then recovers.
    ws = job.worker_status
    if Rails.application.config.x.demo.rollovers_enabled &&
       !job.worker_class.name.start_with?("Sim::") && Sim::RolloverPolicy.roll?(ws)
      Rails.logger.info("[sim] rolling over #{ws&.worker_name} " \
                        "(p=#{Sim::RolloverPolicy.hazard_for(ws).round(5)}, uptime=#{ws&.uptime_s}s)")
      raise Sim::Rollover, "rolling over #{ws&.worker_name}"
    end

    perform.call
  end
end

# Sim::Rollover is app-autoloaded, so it isn't resolvable while initializers run;
# declare it a shutdown error post-boot (to_prepare re-runs on reload to stay fresh).
Rails.application.config.to_prepare do
  Busybee.configure { |config| config.shutdown_on_errors = [Sim::Rollover] }
end
