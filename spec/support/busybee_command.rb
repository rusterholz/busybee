# frozen_string_literal: true

require "concurrent"
require "open3"
require "rbconfig"

# Runs the busybee executable in a process of its own, the way an operator does,
# with the worker in spec/fixtures/cli_logging_worker.rb required ahead of it.
module BusybeeCommand
  EXE = File.expand_path("../../exe/busybee", __dir__)
  WORKER = File.expand_path("../fixtures/cli_logging_worker.rb", __dir__)
  INSECURE = { "BUSYBEE_CREDENTIAL_TYPE" => "insecure" }.freeze
  # The repository's own bundle, which never has rails, whatever row is running.
  WITHOUT_RAILS = { "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }.freeze
  Result = Struct.new(:stdout, :stderr, :status, :stdout_while_running)

  # Returns its stdout, stderr and status (nil if it had to be killed). Given a
  # block, polls it with the stdout so far until it returns truthy, and keeps
  # that stdout as stdout_while_running, read while the process still ran.
  def run_busybee(*args, chdir:, env: {}, seconds: 20, &until_stdout)
    command = [RbConfig.ruby, "-rbundler/setup", "-r", WORKER, EXE, *args]
    Open3.popen3(INSECURE.merge(env), *command, chdir: chdir) do |stdin, out, err, waiter|
      stdin.close
      stdout = StreamBuffer.new(out)
      stderr = StreamBuffer.new(err)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      seen = await(until_stdout, stdout, waiter, deadline) if until_stdout
      status = finish(waiter, deadline)
      Result.new(stdout.read, stderr.read, status, seen)
    end
  end

  private

  def await(condition, stdout, waiter, deadline)
    loop do
      text = stdout.peek
      return text if condition.call(text) && waiter.alive?
      return nil if !waiter.alive? || remaining(deadline).zero?

      sleep 0.02
    end
  end

  def finish(waiter, deadline)
    return waiter.value if waiter.join(remaining(deadline))

    Process.kill("KILL", waiter.pid)
    waiter.join
    nil
  end

  def remaining(deadline) = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max

  # Drains a pipe on a thread of its own, so neither stream can fill and stall the child.
  class StreamBuffer
    def initialize(io)
      @text = +""
      @lock = Mutex.new
      @reader = Thread.new do
        loop do
          chunk = io.readpartial(4096)
          @lock.synchronize { @text << chunk }
        end
      rescue IOError # EOFError included
        nil
      end
    end

    def peek = @lock.synchronize { @text.dup }

    def read
      @reader.join
      peek
    end
  end
end

# A gateway that streams the worker one job, then holds the stream open until
# the job's completion is on stdout, so the run ends with the stream's close,
# after the completion. A run that logs nothing (logged: false) closes it when
# the completion reaches the gateway instead, where the stop can overtake the
# completion's response.
RSpec.shared_context "with a busybee command on a one-job stream" do
  include BusybeeCommand

  let(:stream_gate) { Queue.new }
  let(:job) { FaultInjectionGateway.activated_job(type: "logging_stream") }

  before do
    gateway.on(:stream_activated_jobs) do
      Enumerator.new do |yielder|
        yielder << job
        stream_gate.pop
      end
    end
    gateway.on(:complete_job) do
      stream_gate << :close if close_on_complete.true?
      Busybee::GRPC::CompleteJobResponse.new
    end
  end

  let(:close_on_complete) { Concurrent::AtomicBoolean.new(true) }

  def run_to_completion(*args, chdir:, env: {}, logged: true)
    close_on_complete.value = !logged
    run_busybee("-a", gateway.address, *args, "LoggingStreamWorker", chdir: chdir, env: env, seconds: 15) do |stdout|
      logged && stdout.include?("Completed").tap { |completed| stream_gate << :close if completed }
    end
  end

  # The [busybee] part of each line that has one.
  def messages(stdout) = stdout.lines.filter_map { |line| line[/\[busybee\] .*/] }

  def worker_messages
    ["[busybee] Started LoggingStreamWorker (streaming, job type logging_stream)",
     "[busybee] Completed logging_stream job ##{job.key}",
     "[busybee] Stopping LoggingStreamWorker (gateway_closed)",
     "[busybee] Stopped LoggingStreamWorker (gateway_closed)"]
  end

  def describe_exit(result)
    "#{result.status ? "exited #{result.status.exitstatus}" : 'hung'}:\n#{result.stdout}#{result.stderr}"
  end
end

RSpec.configure do |config|
  config.include_context "with a busybee command on a one-job stream", :busybee_command
end
