# frozen_string_literal: true

# Required with -r into a busybee command run by spec/support/busybee_command.rb:
# the worker a spec's in-process gateway streams one job to. A log format in
# BUSYBEE_SPEC_LOG_FORMAT is configured here, ahead of the command.
require "busybee"

Busybee.log_format = ENV["BUSYBEE_SPEC_LOG_FORMAT"] if ENV["BUSYBEE_SPEC_LOG_FORMAT"]

class LoggingStreamWorker < Busybee::Worker
  job_type "logging_stream"
  worker_mode :streaming

  def perform = {}
end
