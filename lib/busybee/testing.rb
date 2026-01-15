# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  # Testing support for BPMN workflows with RSpec.
  #
  # @example Configuration
  #   Busybee::Testing.configure do |config|
  #     config.activate_request_timeout = 2000
  #   end
  #
  module Testing
    class << self
      attr_writer :activate_request_timeout

      def configure
        yield self
      end

      def activate_request_timeout
        @activate_request_timeout || 1000
      end
    end
  end
end

# Auto-load RSpec integration if RSpec is available
if defined?(RSpec)
  require "busybee/testing/helpers"
  require "busybee/testing/activated_job"
  require "busybee/testing/matchers/have_received_variables"
  require "busybee/testing/matchers/have_received_headers"
  require "busybee/testing/matchers/have_activated"

  RSpec.configure do |config|
    config.include Busybee::Testing::Helpers
  end
end
