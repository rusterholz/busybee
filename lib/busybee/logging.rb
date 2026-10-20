# frozen_string_literal: true

require "json"
require "time"

module Busybee
  # Centralized logging with prefixing and optional JSON formatting.
  #
  # Thread-safe: the logger and format are read once per call, the line is
  # rendered outside the lock, and the lock covers only the logger's write, so
  # concurrent lines can't interleave even on a logger with no lock of its own.
  # Where the lock can't be taken (a trap, a write that itself logs, a sibling
  # fiber holding it) the line is written unlocked rather than lost.
  module Logging
    PREFIX = "[busybee]"
    LOCK = Mutex.new
    # Async interrupts (Thread#kill, #raise) land only where a thread blocks: while
    # it waits its turn or inside the write, never between taking the lock and the
    # ensure that releases it.
    DEFER_INTERRUPTS = { Object => :on_blocking }.freeze
    ALLOW_INTERRUPTS = { Object => :immediate }.freeze
    private_constant :LOCK, :DEFER_INTERRUPTS, :ALLOW_INTERRUPTS

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
        logger = Busybee.logger
        return unless logger

        formatted = case Busybee.log_format
                    when :text then format_text(message, **context)
                    when :json then format_json(level, message, **context)
                    end
        write(logger, level, formatted)
      end

      def write(logger, level, line)
        Thread.handle_interrupt(DEFER_INTERRUPTS) do
          locked = acquire
          begin
            Thread.handle_interrupt(ALLOW_INTERRUPTS) { logger.public_send(level, line) }
          ensure
            LOCK.unlock if locked
          end
        end
      end

      # try_lock first: it works in a trap, where lock raises.
      def acquire
        LOCK.try_lock || LOCK.lock
      rescue ThreadError
        false
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
