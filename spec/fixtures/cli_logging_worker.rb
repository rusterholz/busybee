# frozen_string_literal: true

# Required with -r into a busybee command run by spec/support/busybee_command.rb:
# the worker a spec's in-process gateway streams one job to.
require "busybee"

class LoggingStreamWorker < Busybee::Worker
  job_type "logging_stream"
  worker_mode :streaming

  def perform = {}
end
