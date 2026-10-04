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

  # Run the recorder's writes inline. It normally offloads them to a background
  # thread, whose own connection sits outside the example's transaction — so a
  # hook firing mid-example would commit rows that survive the rollback and leak
  # into later examples. Specs that exercise the writer itself opt back out with
  # and_call_original.
  config.before do
    allow(Monitoring::Recorder).to receive(:executor).and_return(Concurrent::ImmediateExecutor.new)
  end

  # A worker spec asks "does my code do the right thing?", where busybee is
  # scenery. execute_worker fires every hook level, so the app's monitoring hooks
  # would otherwise write rows during one — and an async worker resolves on a
  # background thread, whose connection sits outside the transaction, committing
  # rows that outlive the example. Keep only the perform hooks, which is what a
  # worker spec is about; the domain transactions still wrap perform, because
  # they are registered there.
  config.define_derived_metadata(file_path: %r{/spec/workers/}) do |metadata|
    metadata[:without_busybee_hooks] ||= %i[job worker call]
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
