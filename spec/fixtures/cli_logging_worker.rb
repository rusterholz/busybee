# frozen_string_literal: true

# Required with -r into a busybee command run by spec/support/busybee_command.rb:
# the worker a spec's in-process gateway streams one job to. A log format in
# BUSYBEE_SPEC_LOG_FORMAT, or an address in BUSYBEE_SPEC_CLUSTER_ADDRESS, is
# configured here, ahead of the command, as an app's own config file would be.
require "busybee"

Busybee.log_format = ENV["BUSYBEE_SPEC_LOG_FORMAT"] if ENV["BUSYBEE_SPEC_LOG_FORMAT"]
Busybee.cluster_address = ENV["BUSYBEE_SPEC_CLUSTER_ADDRESS"] if ENV["BUSYBEE_SPEC_CLUSTER_ADDRESS"]

class LoggingStreamWorker < Busybee::Worker
  job_type "logging_stream"
  worker_mode :streaming

  def perform = {}
end
