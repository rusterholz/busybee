# frozen_string_literal: true

# Demo app spec helper
#
# Usage: cd spec/demo && bundle exec rspec
#
# BPMN specs require a running Zeebe instance and are tagged :zeebe.
# They are automatically skipped when Zeebe is unavailable.
# To require Zeebe (e.g., in CI): ZEEBE_REQUIRED=1 bundle exec rspec

require "bundler/setup"
require "busybee"
require "busybee/testing"

# Set credential type to insecure for local Zeebe
Busybee.credential_type = :insecure

BPMN_DIR = File.expand_path("../app/bpmn", __dir__)

# Check Zeebe availability once at load time
ZEEBE_RUNNER = Class.new { include Busybee::Testing::Helpers }.new
ZEEBE_AVAILABLE = ZEEBE_RUNNER.zeebe_available?

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include Busybee::Testing::Helpers in all specs
  config.include Busybee::Testing::Helpers

  # Skip BPMN specs when Zeebe is not running, unless ZEEBE_REQUIRED is set
  unless ZEEBE_AVAILABLE
    if ENV["ZEEBE_REQUIRED"]
      raise "Zeebe is required but not available. Start with: rake zeebe:start"
    end

    config.filter_run_excluding zeebe: true
    config.before(:each, :zeebe) do
      skip "Zeebe is not running (start with: rake zeebe:start)"
    end
  end

  # Deploy all BPMN processes once at suite start when Zeebe is available.
  config.before(:suite) do
    next unless ZEEBE_AVAILABLE

    # TODO: Replace with Busybee::Deployment helpers when available (v0.4+).
    Dir[File.join(BPMN_DIR, "*.bpmn")].each do |bpmn_file|
      ZEEBE_RUNNER.deploy_process(bpmn_file)
    end
  end
end
