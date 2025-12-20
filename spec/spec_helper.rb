# frozen_string_literal: true

require "busybee"
require "busybee/grpc/gateway_pb"
require "busybee/grpc/gateway_services_pb"
require "base64"
require "securerandom"

# Load support files
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Skip integration tests unless explicitly requested via ENV variable
  # To run integration tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec
  # To run only integration tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
  config.filter_run_excluding integration: true unless ENV["RUN_INTEGRATION_TESTS"]
end
