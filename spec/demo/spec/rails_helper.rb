# frozen_string_literal: true

# Rails-aware spec helper for worker and model tests.
#
# Usage: cd spec/demo && bundle exec rspec spec/workers/
#
# Unlike spec_helper.rb (which requires Zeebe for BPMN specs), this helper
# boots the Rails app and sets up a test database. No Zeebe dependency.

ENV["RAILS_ENV"] = "test"

require_relative "../config/environment"
require "rspec"
require "busybee"
require "busybee/testing"

# Disable CSRF protection in tests so Rack::Test requests work without tokens.
ActionController::Base.allow_forgery_protection = false

# Ensure all per-domain test databases exist and are migrated/loaded.
ActiveRecord::Tasks::DatabaseTasks.prepare_all

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Wrap each example in a transaction per database for isolation. Each domain
  # has its own connection, so a single ActiveRecord::Base transaction would roll
  # back only one of them; nest a rolled-back transaction on each domain base.
  # Tag an example :no_transaction to opt out — needed when it spawns threads
  # whose separate connections must see each other's committed writes (e.g.
  # concurrency tests); such examples clean up after themselves.
  config.around do |example|
    next example.run if example.metadata[:no_transaction]

    bases = [Oms::Record, Logistics::Record, Delivery::Record, Monitoring::Record]
    runner = -> { example.run }
    bases.each do |base|
      inner = runner
      runner = lambda do
        base.transaction do
          inner.call
          raise ActiveRecord::Rollback
        end
      end
    end
    runner.call
  end
end
