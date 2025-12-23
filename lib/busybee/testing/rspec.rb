# frozen_string_literal: true

require "busybee/testing"
require "busybee/testing/helpers"
require "busybee/testing/activated_job"
require "busybee/testing/matchers/have_received_variables"
require "busybee/testing/matchers/have_received_headers"
require "busybee/testing/matchers/have_activated"

RSpec.configure do |config|
  config.include Busybee::Testing::Helpers
end
