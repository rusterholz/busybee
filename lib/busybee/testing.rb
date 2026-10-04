# frozen_string_literal: true

require "busybee"

module Busybee
  # Testing support for BPMN workflows and workers with RSpec.
  module Testing
  end
end

# Auto-load RSpec integration if RSpec is available
if defined?(RSpec)
  require "busybee/testing/helpers"
  require "busybee/testing/activated_job"
  require "busybee/testing/matchers/have_received_variables"
  require "busybee/testing/matchers/have_received_headers"
  require "busybee/testing/matchers/have_activated"
  require "busybee/testing/matchers/have_available_jobs"
  require "busybee/testing/matchers/fail_job"
  require "busybee/testing/matchers/complete_job"
  require "busybee/testing/matchers/throw_bpmn_error_on"

  RSpec.configure do |config|
    config.include Busybee::Testing::Helpers

    # `without_busybee_hooks: [:worker, :call]` on a group or example; innermost wins.
    config.around(:example, :without_busybee_hooks) do |example|
      without_busybee_hooks(*example.metadata[:without_busybee_hooks]) { example.run }
    end
  end
end
