# frozen_string_literal: true

require "busybee"
require "json"
require "time"

module Busybee
  # Centralized logging with prefixing and optional JSON formatting.
  # Thread-safe: a mutex serializes format + write so concurrent threads
  # cannot interleave within a single log line.
  module Logging
    PREFIX = "[busybee]"

    class << self
      def debug(message, **context)
        log(:debug, message, **context)
      end

      def info(message, **context)
        log(:info, message, **context)
      end

      def warn(message, **context)
        log(:warn, message, **context)
      end

      def error(message, **context)
        log(:error, message, **context)
      end

      private

      def mutex = @mutex ||= Mutex.new

      def log(level, message, **context)
        return unless Busybee.logger

        mutex.synchronize do
          formatted = case Busybee.log_format
                      when :text then format_text(message, **context)
                      when :json then format_json(level, message, **context)
                      end

          Busybee.logger.public_send(level, formatted)
        end
      end

      def format_text(message, **context)
        formatted = "#{PREFIX} #{message}"
        formatted += " (#{context.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})" if context.any?
        formatted
      end

      # time rides in the payload: the JSON line is emitted pre-formatted, so
      # it can't rely on the host logger's formatter to stamp it.
      def format_json(level, message, **context)
        context.merge(
          message: "#{PREFIX} #{message}",
          level: level.to_s,
          time: Time.now.utc.iso8601(3)
        ).to_json
      end
    end
  end
end
