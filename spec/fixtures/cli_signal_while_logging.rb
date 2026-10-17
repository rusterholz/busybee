# frozen_string_literal: true

# Spawned by spec/busybee/cli_signal_spec.rb. Runs the real CLI three times
# against an in-process gateway, printing "<scenario> exited" after each run
# that returns. In each, on_worker_started's log line sends the process SIGTERM
# from inside the logger's write, and holds the write open while the signal is
# handled; on_worker_stop_requested logs too, so handling the signal needs the
# lock the interrupted write holds.
#
# deadlock: nothing more.
# slow_stop_requested: that hook outlasts the teardown's wait for it, but not
# the CLI's own wait after the run.
# hung_stop_requested: it hangs, and on_worker_stopping fails unrecoverably,
# which crashes the process. Last, since nothing runs after it.
require "concurrent"
require "logger"

require "busybee"
require "busybee/cli"
require "busybee/testing/hook_registry"
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

def register_hooks(scenario)
  Busybee.on_worker_started do |_status|
    ARMED.make_true
    Busybee.logger.info("#{scenario} started")
  end
  Busybee.on_worker_stop_requested do |status|
    sleep({ "slow_stop_requested" => 1.8, "hung_stop_requested" => 30 }.fetch(scenario, 0))
    Busybee.logger.info("#{scenario} stop requested: #{status.reason}")
  end
  Busybee.on_worker_stopping { |_status| raise NoMemoryError, "out of memory" } if scenario == "hung_stop_requested"
end

def run_scenario(scenario, gateway)
  Busybee::Testing::HookRegistry.isolated do
    register_hooks(scenario)
    Busybee::CLI.new(["-a", gateway.address, "--shutdown-wait-timeout", "1000", "SignalledWorker"]).run
    puts "#{scenario} exited" # rubocop:disable RSpec/Output
  end
end

$stdout.sync = true
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
begin
  %w[deadlock slow_stop_requested hung_stop_requested].each { |scenario| run_scenario(scenario, gateway) }
ensure
  gateway.stop # a gRPC server still serving at exit segfaults the interpreter's teardown
end
