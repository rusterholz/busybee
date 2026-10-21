# frozen_string_literal: true

require "logger"

module Busybee
  class CLI
    # The CLI's own logger's formatter: stdlib's line under :text, the bare JSON
    # line under :json. Reads the format per line, since it can change after boot.
    class LogFormatter < ::Logger::Formatter
      def call(severity, time, progname, message)
        Busybee.log_format == :json ? "#{message}\n" : super
      end
    end
  end
end
