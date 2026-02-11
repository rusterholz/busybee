# frozen_string_literal: true

require "busybee/grpc"

module Busybee
  # Testing support for BPMN workflows with RSpec.
  module Testing
  end
end

# Auto-load RSpec integration if RSpec is available
if defined?(RSpec)
  require "busybee/testing/helpers"
  require "busybee/testing/activated_job"
  require "busybee/testing/matchers/have_received_variables"
  require "busybee/testing/matchers/have_received_headers"
  require "busybee/testing/matchers/have_activated"
  require "busybee/testing/matchers/have_available_jobs"

  RSpec.configure do |config|
    config.include Busybee::Testing::Helpers
  end
end
