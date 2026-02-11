# frozen_string_literal: true

require "busybee/worker/configuration"

module Busybee
  class Worker
    # Class-level DSL for declaring worker metadata and configuration.
    # Extended into Worker subclasses.
    #
    # Mission 7: job_type, description, configuration
    # Mission 8: input, variable, header, output, runner_mode, polling, streaming, job_timeout, backoff
    # Mission 9: autocomplete, autofail, unhealthy_on
    module DSL
      def configuration
        @configuration ||= Configuration.new(self)
      end

      def job_type(value = nil)
        if value.nil?
          configuration.job_type
        else
          configuration.job_type = value
        end
      end

      def description(value = nil)
        if value.nil?
          configuration.description
        else
          configuration.description = value
        end
      end

      # Mission 8: input, variable, header, output, runner_mode, polling, streaming, job_timeout, backoff
      # Mission 9: autocomplete, autofail, unhealthy_on
    end
  end
end
