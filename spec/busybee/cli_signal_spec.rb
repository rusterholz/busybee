# frozen_string_literal: true

require "open3"
require "rbconfig"

# A termination signal handled while the worker process's main thread is
# mid-write in its logger, run as a real process: three runs of the CLI, one
# per scenario of the fixture, in order.
RSpec.describe "the CLI receiving a signal mid-log-write" do # rubocop:disable RSpec/DescribeClass
  # Returns [output, status], or [output, nil] if it had to be killed.
  def self.run_fixture(seconds: 10)
    fixture = File.expand_path("../fixtures/cli_signal_while_logging.rb", __dir__)
    Open3.popen2e({ "BUSYBEE_SKIP_RAILS" => "1" }, RbConfig.ruby, fixture) do |_stdin, output, waiter|
      unless waiter.join(seconds)
        Process.kill("KILL", waiter.pid)
        return [output.read, nil]
      end

      [output.read, waiter.value]
    end
  end

  # One process serves every example: booting one costs more than the scenarios.
  def self.fixture_run = @fixture_run ||= run_fixture
  def output = self.class.fixture_run.first
  def status = self.class.fixture_run.last

  it "stops the worker, announcing the stop, and exits" do
    expect(output).to match(/deadlock stop requested: sigterm.*^deadlock exited$/m)
  end

  it "lets the stop announcement finish before exiting, even past shutdown_wait_timeout" do
    expect(output).to match(/slow_stop_requested stop requested: sigterm.*^slow_stop_requested exited$/m)
  end

  it "crashes on the error that says to exit immediately, without waiting for a stop announcement" do
    aggregate_failures do
      expect(output).to include("out of memory (NoMemoryError)")
      expect(output).not_to include("hung_stop_requested stop requested")
      expect(output).not_to include("hung_stop_requested exited")
    end
  end

  it "ends the process with a failing status rather than hanging" do
    expect(status&.exitstatus).to eq(1), "the process #{status ? "exited #{status.exitstatus}" : 'hung'}:\n#{output}"
  end
end
