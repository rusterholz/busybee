# frozen_string_literal: true

require "open3"
require "rbconfig"

# A termination signal handled while the worker process's main thread is
# mid-write in its logger, run as a real process.
RSpec.describe "the CLI receiving a signal mid-log-write" do # rubocop:disable RSpec/DescribeClass
  let(:fixture) { File.expand_path("../fixtures/cli_signal_while_logging.rb", __dir__) }

  # Returns [output, status], or [output, nil] if it had to be killed.
  def run_fixture(scenario: "deadlock", seconds: 8)
    env = { "BUSYBEE_SKIP_RAILS" => "1", "SCENARIO" => scenario }
    Open3.popen2e(env, RbConfig.ruby, fixture) do |_stdin, output, waiter|
      unless waiter.join(seconds)
        Process.kill("KILL", waiter.pid)
        return [output.read, nil]
      end

      [output.read, waiter.value]
    end
  end

  def expect_exit(output, status)
    expect(status&.success?).to be(true), "the process #{status ? 'failed' : 'hung'}:\n#{output}"
  end

  it "stops the worker, announcing the stop, and exits" do
    output, status = run_fixture

    aggregate_failures do
      expect_exit(output, status)
      expect(output).to include("stop requested: sigterm", "exited")
    end
  end

  it "lets the stop announcement finish before exiting, even past shutdown_wait_timeout" do
    output, status = run_fixture(scenario: "slow_stop_requested")

    aggregate_failures do
      expect_exit(output, status)
      expect(output.index("stop requested: sigterm")).to be < output.index("exited")
    end
  end

  it "exits without waiting for a stop announcement once the process must exit immediately" do
    output, status = run_fixture(scenario: "hung_stop_requested", seconds: 5)

    aggregate_failures do
      expect_exit(output, status)
      expect(output).not_to include("stop requested")
    end
  end
end
