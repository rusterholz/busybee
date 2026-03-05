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

# Ensure test database exists and is migrated.
ActiveRecord::Tasks::DatabaseTasks.create_current
ActiveRecord::MigrationContext.new(
  Rails.root.join("db/migrate")
).migrate

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Wrap each example in a database transaction for isolation.
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
