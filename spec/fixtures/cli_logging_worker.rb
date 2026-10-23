# frozen_string_literal: true

# Required with -r into a busybee command run by spec/support/busybee_command.rb:
# the worker a spec's in-process gateway streams one job to. The BUSYBEE_SPEC_*
# variables configure a log format, address or credentials ahead of the command,
# as an app's own config file would.
require "busybee"
require "busybee/credentials/insecure"

Busybee.log_format = ENV["BUSYBEE_SPEC_LOG_FORMAT"] if ENV["BUSYBEE_SPEC_LOG_FORMAT"]
Busybee.cluster_address = ENV["BUSYBEE_SPEC_CLUSTER_ADDRESS"] if ENV["BUSYBEE_SPEC_CLUSTER_ADDRESS"]
if ENV["BUSYBEE_SPEC_CREDENTIALS_ADDRESS"]
  Busybee.credentials = Busybee::Credentials::Insecure.new(cluster_address: ENV["BUSYBEE_SPEC_CREDENTIALS_ADDRESS"])
end

class LoggingStreamWorker < Busybee::Worker
  job_type "logging_stream"
  worker_mode :streaming

  def perform = {}
end
