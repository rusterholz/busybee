# frozen_string_literal: true

require "json"
require "time"

require "busybee/runner/exit_immediately"

module Busybee
  # Centralized logging with prefixing and optional JSON formatting.
  #
  # Safe by construction: a call returns nil and never raises, so it may sit
  # anywhere, a rescue clause included. What fails inside it is told to stderr,
  # after raising the fire alarm for an error the process can't recover from;
  # bytes that aren't UTF-8 in the message or a top-level String are replaced.
  #
  # Thread-safe: the logger and format are read once per call, the line is
  # rendered outside the lock, and the lock covers only the logger's write, so
  # concurrent lines can't interleave even on a logger with no lock of its own.
  # Where the lock can't be taken (a trap, a write that itself logs, a sibling
  # fiber holding it) the line is written unlocked rather than lost.
  module Logging
    extend Runner::ExitImmediately

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

        message = utf8(message)
        formatted = case Busybee.log_format
                    when :text then format_text(message, context)
                    when :json then format_json(level, message, carrier, error, context)
                    end
        write(logger, level, formatted)
        nil
      rescue Exception => e # rubocop:disable Lint/RescueException
        failed_to_log(e, message)
      end

      # The alarm first: raising it allocates nothing, the notice may not survive.
      def failed_to_log(error, message)
        exit_immediately!(reason: :crash) unless Runner::RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }
        $stderr.write("#{PREFIX} failed to log (#{error.class}: #{error.message}): #{message}\n")
        nil
      rescue Exception # rubocop:disable Lint/RescueException
        nil
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
        fields.transform_values! { |value| utf8(renderable(value)) }
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

      # A BINARY or invalid String is copied as UTF-8 and scrubbed; anything else,
      # a clean or ASCII-only String included, passes through untouched.
      def utf8(value)
        return value unless value.is_a?(String) && !value.ascii_only?
        return value if value.valid_encoding? && value.encoding != Encoding::BINARY

        value.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
