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

# Disable CSRF protection in tests so Rack::Test requests work without tokens.
ActionController::Base.allow_forgery_protection = false

# Ensure test database exists and is migrated.
ActiveRecord::Tasks::DatabaseTasks.create_current
ActiveRecord::MigrationContext.new(
  Rails.root.join("db/migrate")
).migrate

# Minimal mock helpers for testing workers without busybee's forthcoming
# test harness (v0.3). These build a mock Busybee::Job that workers can
# call perform_job against.
module WorkerTestHelper
  def build_worker_job(variables: {}, headers: {})
    client = double("Busybee::Client", complete_job: nil, fail_job: nil) # rubocop:disable RSpec/VerifiedDoubles
    raw_job = double( # rubocop:disable RSpec/VerifiedDoubles
      "Busybee::GRPC::ActivatedJob",
      key: rand(100_000..999_999),
      type: "test",
      processInstanceKey: rand(100_000..999_999),
      bpmnProcessId: "test-process",
      retries: 3,
      deadline: (Time.now.to_i + 300) * 1000,
      variables: variables.to_json,
      customHeaders: headers.to_json
    )
    Busybee::Job.new(raw_job, client: client)
  end

  def execute_worker(worker_class, variables: {}, headers: {})
    job = build_worker_job(variables: variables, headers: headers)
    worker_class.perform_job(job)
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include WorkerTestHelper

  # Wrap each example in a database transaction for isolation.
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
