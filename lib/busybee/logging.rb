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

    # Each level takes an optional carrier (a Job, Worker::Status or Client::Call:
    # anything answering logging_context) and an error. Both enrich JSON only; in
    # text the call site has already written what matters into the message.
    class << self
      def debug(message, carrier = nil, error: nil, **context) = log(:debug, message, carrier, error, context)
      def info(message, carrier = nil, error: nil, **context) = log(:info, message, carrier, error, context)
      def warn(message, carrier = nil, error: nil, **context) = log(:warn, message, carrier, error, context)
      def error(message, carrier = nil, error: nil, **context) = log(:error, message, carrier, error, context)

      private

      def log(level, message, carrier, error, context)
        unless carrier.nil? || carrier.respond_to?(:logging_context)
          raise ArgumentError, "a log carrier answers logging_context; got #{carrier.class}"
        end

        logger = Busybee.logger
        return unless logger

        formatted = case Busybee.log_format
                    when :text then format_text(message, context)
                    when :json then format_json(level, message, carrier, error, context)
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

      def format_text(message, context)
        formatted = "#{PREFIX} #{message}"
        formatted += " (#{context.map { |k, v| "#{k}: #{renderable(v).inspect}" }.join(', ')})" if context.any?
        formatted
      end

      # Later layers win: the carrier's context, the call site's, the error's,
      # then the line's own fields. time rides in the payload: the JSON line is
      # emitted pre-formatted, so the host logger's formatter can't stamp it.
      def format_json(level, message, carrier, error, context)
        fields = carrier ? carrier.logging_context.merge(context) : context.dup
        fields.merge!(error_fields(error)) if error
        fields.transform_values! { |value| renderable(value) }
        fields.merge(message: "#{PREFIX} #{message}", level: level.to_s, time: Time.now.utc.iso8601(3)).to_json
      end

      # A location only below the recoverable line: there, materializing the
      # backtrace is one more allocation the process may not survive.
      def error_fields(error)
        fields = { error_class: error.class.name, error_message: error.message }
        location = error.backtrace&.first if error.is_a?(StandardError)
        location ? fields.merge(error_location: location) : fields
      end

      def renderable(value) = value.is_a?(Exception) ? "[#{value.class}] #{value.message}" : value
    end
  end
end
