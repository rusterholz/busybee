# frozen_string_literal: true

require "busybee"
require "json"

module Busybee
  # Centralized logging with prefixing and optional JSON formatting.
  # Thread-safe mutex support will be added in v0.3 when Worker abstraction introduces multi-threading.
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

      def log(level, message, **context)
        return unless Busybee.logger

        formatted = case Busybee.log_format
                    when :text then format_text(message, **context)
                    when :json then format_json(level, message, **context)
                    end

        Busybee.logger.public_send(level, formatted)
      end

      def format_text(message, **context)
        formatted = "#{PREFIX} #{message}"
        formatted += " (#{context.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})" if context.any?
        formatted
      end

      def format_json(level, message, **context)
        context.merge(
          message: "#{PREFIX} #{message}",
          level: level.to_s
        ).to_json
      end
    end
  end
end
