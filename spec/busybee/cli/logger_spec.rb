# frozen_string_literal: true

require "json"
require "tmpdir"

# The busybee command's own logger, run as a real process outside Rails, on a
# streaming worker the in-process gateway hands one job and then holds open.
RSpec.describe "the busybee command's logger", :busybee_command, :gateway do # rubocop:disable RSpec/DescribeClass
  let(:stream_gate) { Queue.new }
  let(:job) { FaultInjectionGateway.activated_job(type: "logging_stream") }

  before do
    gateway.on(:stream_activated_jobs) do
      Enumerator.new do |yielder|
        yielder << job
        stream_gate.pop
      end
    end
    gateway.on(:complete_job) { Busybee::GRPC::CompleteJobResponse.new }
  end

  # Closes the stream once the job's completion is on stdout, so the worker stops.
  def run_to_completion(*args)
    Dir.mktmpdir do |dir|
      run_busybee("-a", gateway.address, *args, "LoggingStreamWorker",
                  chdir: dir, env: { "BUSYBEE_SKIP_RAILS" => "1" }, seconds: 10) do |stdout|
        stdout.include?("Completed").tap { |completed| stream_gate << :close if completed }
      end
    end
  end

  def messages(stdout) = stdout.lines.map { |line| line[/\[busybee\] .*/] }

  it "logs each line to stdout at info as it happens" do
    result = run_to_completion

    expect(result.status&.exitstatus).to eq(0), "#{result.status ? "exited #{result.status.exitstatus}" : 'hung'}:\n" \
                                                "#{result.stdout}#{result.stderr}"
    expect(result.stdout_while_running).to match(/INFO -- : \[busybee\] Completed logging_stream job ##{job.key}\n/)
    expect(messages(result.stdout)).to eq(["[busybee] Started LoggingStreamWorker (streaming, job type logging_stream)",
                                           "[busybee] Completed logging_stream job ##{job.key}",
                                           "[busybee] Stopping LoggingStreamWorker (gateway_closed)",
                                           "[busybee] Stopped LoggingStreamWorker (gateway_closed)"])
    expect(result.stderr).to eq("")
  end

  it "logs in the --log-format given" do
    result = run_to_completion("-l", "json")

    lines = result.stdout.lines.map { |line| JSON.parse(line[/\{.*\}/]) }
    expect(lines.map { |line| line.values_at("level", "message") }).to eq(
      [["info", "[busybee] Started LoggingStreamWorker (streaming, job type logging_stream)"],
       ["info", "[busybee] Completed logging_stream job ##{job.key}"],
       ["info", "[busybee] Stopping LoggingStreamWorker (gateway_closed)"],
       ["info", "[busybee] Stopped LoggingStreamWorker (gateway_closed)"]]
    )
  end
end
