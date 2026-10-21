# frozen_string_literal: true

require "open3"
require "rbconfig"

# Runs the busybee executable in a process of its own, the way an operator does,
# with the worker in spec/fixtures/cli_logging_worker.rb required ahead of it.
module BusybeeCommand
  EXE = File.expand_path("../../exe/busybee", __dir__)
  WORKER = File.expand_path("../fixtures/cli_logging_worker.rb", __dir__)
  INSECURE = { "BUSYBEE_CREDENTIAL_TYPE" => "insecure" }.freeze
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

RSpec.configure { |config| config.include BusybeeCommand, :busybee_command }
