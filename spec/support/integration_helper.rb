# frozen_string_literal: true

# Integration test helper for testing busybee against a real Zeebe instance
#
# Usage:
#   1. Start Zeebe: rake zeebe:start && rake zeebe:health
#   2. Run tests: RUN_INTEGRATION_TESTS=1 bundle exec rspec --tag integration
#
# Tests will skip gracefully if Zeebe is not running, unless ZEEBE_REQUIRED=1
# is set, in which case tests will fail (useful for CI).

module IntegrationHelpers
  # Skips or fails the current test if Zeebe is not available
  #
  # By default, tests skip gracefully when Zeebe is not running (for local dev).
  # Set ZEEBE_REQUIRED=1 to fail instead of skip (for CI).
  #
  # Call this in a before block:
  #
  #   before do
  #     skip_unless_zeebe_available
  #   end
  def skip_unless_zeebe_available
    return if zeebe_available?

    raise "Zeebe is required but not available at #{Busybee::Testing.address}" if ENV["ZEEBE_REQUIRED"]

    skip "Zeebe is not running (start with: rake zeebe:start)"
  end
end

RSpec.configure do |config|
  # Include integration helpers in all integration tests
  config.include IntegrationHelpers, integration: true

  # Check Zeebe availability before running integration tests
  config.before(:each, :integration) do
    skip_unless_zeebe_available
  end
end
