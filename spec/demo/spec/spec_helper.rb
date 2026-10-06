# frozen_string_literal: true

# Loaded for every demo spec, by .rspec. The BPMN specs are tagged :zeebe and
# skip when Zeebe is down; ZEEBE_REQUIRED=1 makes that an error instead.

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

  # The BPMN specs opt in to busybee's helpers as a directory; rails_helper opts
  # in the worker specs the same way.
  config.define_derived_metadata(file_path: %r{/spec/bpmn/}) do |metadata|
    metadata[:busybee] = true
  end

  unless ZEEBE_AVAILABLE
    raise "Zeebe is required but not available. Start with: rake zeebe:start" if ENV["ZEEBE_REQUIRED"]

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
