# frozen_string_literal: true

# Spawned by spec/busybee/cli_signal_spec.rb. Runs the real CLI against an
# in-process gateway; on_worker_started's log line sends the process SIGTERM
# from inside the logger's write, and holds the write open while the signal is
# handled. on_worker_stop_requested logs too, so handling the signal needs the
# lock the interrupted write holds. Prints "exited" once the CLI returns.
#
# SCENARIO=slow_stop_requested: that hook finishes after shutdown_wait_timeout.
# SCENARIO=hung_stop_requested: it hangs, and on_worker_stopping then fails
# unrecoverably, so the process must exit immediately.
require "concurrent"
require "logger"

require "busybee"
require "busybee/cli"
require_relative "../support/fault_injection_gateway"

ARMED = Concurrent::AtomicBoolean.new(false)

# The log device the logger writes through.
class SignallingDevice
  def write(message)
    if ARMED.make_false
      Process.kill("TERM", Process.pid)
      sleep 0.3
    end
    $stdout.write(message) # rubocop:disable RSpec/Output
  end

  def close; end
end

$stdout.sync = true
scenario = ENV.fetch("SCENARIO", "deadlock")
gateway = FaultInjectionGateway.new.start
gateway.on(:activate_jobs) do
  sleep 0.05
  [Busybee::GRPC::ActivateJobsResponse.new(jobs: [])]
end

Object.const_set(:SignalledWorker, Class.new(Busybee::Worker) do
  job_type "signalled"
  worker_mode :polling

  def perform = {}
end)

Busybee.logger = Logger.new(SignallingDevice.new)
Busybee.credential_type = :insecure
Busybee.on_worker_started do |_status|
  ARMED.make_true
  Busybee.logger.info("started")
end
Busybee.on_worker_stop_requested do |status|
  sleep({ "slow_stop_requested" => 0.5, "hung_stop_requested" => 30 }.fetch(scenario, 0))
  Busybee.logger.info("stop requested: #{status.reason}")
end
Busybee.on_worker_stopping { |_status| raise NoMemoryError, "out of memory" } if scenario == "hung_stop_requested"

Busybee::CLI.new(["-a", gateway.address, "--shutdown-wait-timeout", "100", "SignalledWorker"]).run
puts "exited" # rubocop:disable RSpec/Output
gateway.stop
