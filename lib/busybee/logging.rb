# frozen_string_literal: true

require "json"
require "time"

require "busybee/runner/exit_immediately"

module Busybee
  # Centralized logging with prefixing and optional JSON formatting.
  #
  # Safe by construction: a call returns nil and never raises, so it may sit
  # anywhere, a rescue clause included. What fails inside it, a misused argument
  # included, is told to stderr, after raising the fire alarm for an error the
  # process can't recover from; bytes that aren't UTF-8 in the message or a
  # top-level String are replaced.
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
    # Thread#kill and #raise aimed at a logging thread wait until the call returns,
    # so they land in the caller, outside the containment. A real signal isn't held.
    DEFER_INTERRUPTS = { Object => :never }.freeze
    private_constant :LOCK, :DEFER_INTERRUPTS

    # Each level takes an optional carrier (a Job, Worker::Status or Client::Call:
    # anything answering logging_context), which enriches JSON only, and an error,
    # appended to the message as "(Class: message)" in both formats.
    class << self
      def debug(message, carrier = nil, error: nil, **context) = log(:debug, message, carrier, error, context)
      def info(message, carrier = nil, error: nil, **context) = log(:info, message, carrier, error, context)
      def warn(message, carrier = nil, error: nil, **context) = log(:warn, message, carrier, error, context)
      def error(message, carrier = nil, error: nil, **context) = log(:error, message, carrier, error, context)

      private

      def log(level, message, carrier, error, context)
        Thread.handle_interrupt(DEFER_INTERRUPTS) { contained_log(level, message, carrier, error, context) }
      end

      def contained_log(level, message, carrier, error, context)
        validate_arguments(carrier, error)
        logger = Busybee.logger
        return unless logger

        message = utf8(message)
        message = "#{message} (#{utf8(renderable(error))})" if error
        formatted = case Busybee.log_format
                    when :text then format_text(message, context)
                    when :json then format_json(level, message, carrier, error, context)
                    end
        write(logger, level, formatted)
        nil
      rescue Exception => e # rubocop:disable Lint/RescueException
        failed_to_log(e, message)
      end

      def validate_arguments(carrier, error)
        unless carrier.nil? || carrier.respond_to?(:logging_context)
          raise ArgumentError, "a log carrier answers logging_context; got #{carrier.class}"
        end
        return if error.nil? || error.is_a?(Exception)

        raise ArgumentError, "error: takes an Exception; got #{error.class}"
      end

      # The alarm first: raising it allocates nothing, the notice may not survive.
      def failed_to_log(error, message)
        exit_immediately!(reason: :crash) unless recoverable?(error)
        $stderr.write("#{PREFIX} Failed to log (#{error.class}: #{error.message}): #{message}\n")
        nil
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      def write(logger, level, line)
        locked = acquire
        logger.public_send(level, line)
      ensure
        LOCK.unlock if locked
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
        fields = layered_fields(carrier, context)
        fields.merge!(error_fields(error)) if error
        fields.transform_values! { |value| utf8(renderable(value)) }
        fields.merge(message: "#{PREFIX} #{message}", level: level.to_s, time: Time.now.utc.iso8601(3)).to_json
      end

      # Symbol keys throughout, so a carrier's String "message" can't sit beside the line's own.
      def layered_fields(carrier, context)
        fields = carrier ? carrier.logging_context.merge(context) : context
        fields.transform_keys { |key| key.is_a?(Symbol) ? key : key.to_s.to_sym }
      end

      # A location only for a recoverable error: materializing a non-recoverable
      # one's backtrace is one more allocation the process may not survive.
      def error_fields(error)
        fields = { error_class: error.class.name, error_message: error.message }
        location = error.backtrace&.first if recoverable?(error)
        location ? fields.merge(error_location: location) : fields
      end

      def recoverable?(error) = Runner::RECOVERABLE_ERRORS.any? { |klass| error.is_a?(klass) }

      def renderable(value) = value.is_a?(Exception) ? "#{value.class}: #{value.message}" : value

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
