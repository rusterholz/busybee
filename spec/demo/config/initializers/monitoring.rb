# frozen_string_literal: true

# Operational monitoring for the demo: busybee lifecycle hooks that record every
# job run into Monitoring::JobRun, surfaced on the dark "Monitoring" dashboard.
# This shows how a real consumer plugs an observability sink into busybee — the
# app configures the hooks; here the sink is a local table instead of Datadog.
#
# on_job_activated / on_job_executed are fired by the runner with safe: true, so
# a failure in these hooks can never disrupt job execution. The recorder adds a
# small retry of its own because the demo's worker containers share one SQLite
# file. The two hooks bracket the lifecycle: activation captures the live buffer
# state and start timestamp; execution completes the row with timings + outcome.
Busybee.on_job_activated { |job| Monitoring::Recorder.record_activation(job) }
Busybee.on_job_executed  { |job| Monitoring::Recorder.record_execution(job) }
