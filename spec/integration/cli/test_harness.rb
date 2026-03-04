# frozen_string_literal: true

# Test harness for CLI integration tests.
#
# Spawned as a subprocess by cli_spec.rb. Loads busybee and test workers,
# sets insecure credentials for local Zeebe, then delegates to CLI.main.
#
# Usage:
#   bundle exec ruby spec/integration/cli/test_harness.rb CLITestWorker
#   bundle exec ruby spec/integration/cli/test_harness.rb --config config.yml

require "busybee"
require_relative "test_workers"

Busybee.credential_type = :insecure
Busybee::CLI.main(ARGV)
