# frozen_string_literal: true

# Demo app spec helper
#
# Usage: cd spec/demo && bundle exec rspec
#
# These specs test the demo app's BPMN processes, workers, and integration
# against a running Zeebe instance.

require "bundler/setup"
require "busybee"
require "busybee/testing"

# Set credential type to insecure for local Zeebe
Busybee.credential_type = :insecure

BPMN_DIR = File.expand_path("../app/bpmn", __dir__)

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include Busybee::Testing::Helpers in all specs
  config.include Busybee::Testing::Helpers

  # Skip all demo specs if Zeebe is not running; deploy BPMNs if it is.
  config.before(:suite) do
    runner = Class.new { include Busybee::Testing::Helpers }.new
    unless runner.zeebe_available?
      raise "Zeebe is required but not available. Start with: rake zeebe:start" if ENV["ZEEBE_REQUIRED"]

      warn "Zeebe is not running - skipping demo specs (start with: rake zeebe:start)"
      exit 0
    end

    # Deploy all BPMN processes once at suite start.
    # TODO: Replace with Busybee::Deployment helpers when available (v0.4+).
    Dir[File.join(BPMN_DIR, "*.bpmn")].each do |bpmn_file|
      runner.deploy_process(bpmn_file)
    end
  end
end
