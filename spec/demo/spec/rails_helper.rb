# frozen_string_literal: true

# Boots the Rails app and its test databases, for worker, model and request
# specs. No Zeebe dependency.

ENV["RAILS_ENV"] = "test"

require_relative "../config/environment"
require "rspec"
require "busybee"
require "busybee/testing"

ActionController::Base.allow_forgery_protection = false # Rack::Test requests carry no token
ActiveRecord::Tasks::DatabaseTasks.prepare_all

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # The recorder writes on a background thread whose connection sits outside the
  # example's transaction, so its rows would outlive the example. Run it inline;
  # specs of the writer itself opt back out with and_call_original.
  config.before do
    allow(Monitoring::Recorder).to receive(:executor).and_return(Concurrent::ImmediateExecutor.new)
  end

  # Worker specs opt in to busybee's helpers as a directory. They keep only the
  # perform hooks, which hold the domain transactions; the monitoring hooks would
  # write rows, some from an async worker's thread, outside the transaction.
  config.define_derived_metadata(file_path: %r{/spec/workers/}) do |metadata|
    metadata[:busybee] = true
    metadata[:without_busybee_hooks] ||= %i[job worker call]
  end

  # One rolled-back transaction per domain database, since each has its own
  # connection. Tag an example :no_transaction to opt out, for threads whose
  # connections must see each other's writes; such examples clean up after themselves.
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
