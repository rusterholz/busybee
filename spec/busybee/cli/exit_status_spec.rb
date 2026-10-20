# frozen_string_literal: true

require "open3"
require "rbconfig"

# The CLI's exit status when the engine closes a streaming worker's job stream,
# run as a real process.
RSpec.describe "the CLI's exit status" do # rubocop:disable RSpec/DescribeClass
  # Returns [output, status], or [output, nil] if it had to be killed.
  def run_fixture(*args, seconds: 10)
    fixture = File.expand_path("../../fixtures/cli_stream_close.rb", __dir__)
    Open3.popen2e({ "BUSYBEE_SKIP_RAILS" => "1" }, RbConfig.ruby, fixture, *args) do |_stdin, output, waiter|
      unless waiter.join(seconds)
        Process.kill("KILL", waiter.pid)
        return [output.read, nil]
      end

      [output.read, waiter.value]
    end
  end

  it "is 0 after a clean stop" do
    output, status = run_fixture

    expect(status&.exitstatus).to eq(0), "the process #{status ? "exited #{status.exitstatus}" : 'hung'}:\n#{output}"
  end

  it "is 1 when the stream reader met an error the process can't recover from, though the run returned" do
    output, status = run_fixture("failing_stop_requested")

    expect(status&.exitstatus).to eq(1), "the process #{status ? "exited #{status.exitstatus}" : 'hung'}:\n#{output}"
  end

  it "logs the stream reader's error, then why it exits 1" do
    output, = run_fixture("failing_stop_requested")
    logged = output.lines.grep(/\[busybee\]/)

    expect(logged).to match([
                              /ERROR -- : \[busybee\] Unrecoverable error after ClosingStreamWorker began stopping \(gateway_closed\), exiting immediately \(NoMemoryError: out of memory\)/, # rubocop:disable Layout/LineLength
                              /ERROR -- : \[busybee\] Exiting with status 1: the process must exit immediately \(reason: :crash\)/ # rubocop:disable Layout/LineLength
                            ])
  end

  it "logs nothing of its own after a clean stop" do
    output, = run_fixture

    expect(output.lines.grep(/\[busybee\]/)).to be_empty
  end
end
