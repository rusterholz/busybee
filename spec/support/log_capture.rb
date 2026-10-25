# frozen_string_literal: true

require "json"
require "logger"
require "stringio"

# busybee's log lines, read back through a real Logger. Text lines come back as
# "LEVEL message" strings, JSON lines parsed.
module LogCapture
  # The raw slots, since a logger restored through its setter counts as configured.
  LOGGER_STATE = %i[@logger @logger_configured @log_format].freeze

  AWAIT_SECONDS = 5

  # awaiting: a pattern a line written on another thread must match before the
  # capture ends, waited for up to AWAIT_SECONDS.
  def capture_busybee_log(format: :text, level: Logger::DEBUG, awaiting: nil)
    output = StringIO.new
    preserving_busybee_logger do
      Busybee.logger = capturing_logger(output, format).tap { |logger| logger.level = level }
      Busybee.log_format = format
      yield
      await_line(output, awaiting) if awaiting
    end
    read_captured(output, format)
  end

  def preserving_busybee_logger
    saved = LOGGER_STATE.to_h { |ivar| [ivar, Busybee.instance_variable_get(ivar)] }
    yield
  ensure
    saved.each { |ivar, value| Busybee.instance_variable_set(ivar, value) }
  end

  private

  def capturing_logger(output, format)
    Logger.new(output).tap do |logger|
      logger.formatter = proc do |severity, _time, _progname, line|
        format == :json ? "#{line}\n" : "#{severity} #{line}\n"
      end
    end
  end

  def await_line(output, pattern)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
    sleep 0.01 until output.string.match?(pattern) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def read_captured(output, format)
    lines = output.string.lines(chomp: true)
    format == :json ? lines.map { |line| JSON.parse(line) } : lines
  end
end

RSpec.configure do |config|
  config.include LogCapture
  # A logger an example installs, the CLI's included, never outlives it.
  config.around { |example| preserving_busybee_logger(&example) }
end
