# frozen_string_literal: true

# Spawned by spec/busybee/cli/exit_status_spec.rb. Runs the real CLI once, on a
# streaming worker whose job stream the in-process gateway closes at once, and
# exits however the CLI does, logging to stdout. With "failing_stop_requested"
# as its argument, on_worker_stop_requested raises a NoMemoryError on the
# stream reader.
require "logger"

require "busybee"
require "busybee/cli"
require_relative "../support/fault_injection_gateway"

gateway = FaultInjectionGateway.new.start
gateway.on(:stream_activated_jobs) { [] }

Object.const_set(:ClosingStreamWorker, Class.new(Busybee::Worker) do
  job_type "closing_stream"
  worker_mode :streaming

  def perform = {}
end)

if ARGV.first == "failing_stop_requested"
  Busybee.on_worker_stop_requested { |_status| raise NoMemoryError, "out of memory" }
end

Busybee.credential_type = :insecure
Busybee.logger = Logger.new($stdout)
begin
  Busybee::CLI.new(["-a", gateway.address, "ClosingStreamWorker"]).run
ensure
  gateway.stop # a gRPC server still serving at exit segfaults the interpreter's teardown
end
