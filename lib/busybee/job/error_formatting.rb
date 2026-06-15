# frozen_string_literal: true

module Busybee
  class Job
    # Stateless input-shaping helpers used by Job's lifecycle methods to
    # translate user-friendly arguments (Exception, Symbol, String) into the
    # forms the engine and Resolution expect: a formatted error string for
    # `fail_job`, an uppercase error code for `throw_bpmn_error`, and the
    # error-data hash passed to `Resolution#set_error`.
    module ErrorFormatting
      private

      def format_error_message(message_or_exception)
        return message_or_exception unless message_or_exception.is_a?(Exception)

        message = "[#{message_or_exception.class.name}] #{message_or_exception.message}"
        if (cause = message_or_exception.cause)
          message += " (caused by: [#{cause.class.name}] #{cause.message})"
        end
        message
      end

      def format_error_code(code_or_exception)
        case code_or_exception
        when Symbol
          code_or_exception.to_s.upcase
        when Exception
          # Convert MyApp::Domain::OrderNotFoundError to MY_APP_DOMAIN_ORDER_NOT_FOUND_ERROR
          code_or_exception.class.name.gsub("::", "_").underscore.upcase
        else
          code_or_exception.to_s
        end
      end

      def bpmn_error_data(code_or_exception, code, message)
        data = { error_code: code, error_message: message }
        data[:error] = code_or_exception if code_or_exception.is_a?(Exception)
        data
      end
    end
  end
end
