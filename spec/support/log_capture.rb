# frozen_string_literal: true

require "json"
require "logger"
require "stringio"

# busybee's log lines, read back through a real Logger. Text lines come back as
# "LEVEL message" strings, JSON lines parsed.
module LogCapture
  def capture_busybee_log(format: :text)
    output = StringIO.new
    saved = [Busybee.logger, Busybee.instance_variable_get(:@log_format)]
    Busybee.logger = capturing_logger(output, format)
    Busybee.log_format = format
    yield
    read_captured(output, format)
  ensure
    Busybee.logger, = saved
    Busybee.instance_variable_set(:@log_format, saved.last)
  end

  private

  def capturing_logger(output, format)
    Logger.new(output).tap do |logger|
      logger.formatter = proc do |severity, _time, _progname, line|
        format == :json ? "#{line}\n" : "#{severity} #{line}\n"
      end
    end
  end

  def read_captured(output, format)
    lines = output.string.lines(chomp: true)
    format == :json ? lines.map { |line| JSON.parse(line) } : lines
  end
end

RSpec.configure { |config| config.include LogCapture }
