# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  # Testing support for BPMN workflows with RSpec.
  #
  # @example Configuration
  #   Busybee::Testing.configure do |config|
  #     config.address = "localhost:26500"
  #     config.username = "demo"
  #     config.password = "demo"
  #     config.activate_request_timeout = 2000
  #   end
  #
  module Testing
    class << self
      attr_writer :address, :username, :password, :activate_request_timeout

      def configure
        yield self
      end

      def address
        @address || ENV["ZEEBE_ADDRESS"] || "localhost:26500"
      end

      def username
        @username || ENV["ZEEBE_USERNAME"] || "demo"
      end

      def password
        @password || ENV["ZEEBE_PASSWORD"] || "demo"
      end

      def activate_request_timeout
        @activate_request_timeout || 1000
      end
    end
  end
end
