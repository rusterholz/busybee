# frozen_string_literal: true

require "busybee"

module Busybee
  # Testing support for BPMN workflows and workers with RSpec.
  module Testing
  end
end

# Auto-load RSpec integration if RSpec is available
if defined?(RSpec)
  require "busybee/testing/activated_job"
  require "busybee/testing/helpers"
  require "busybee/testing/helpers/hook_scoping"

  RSpec.configure do |config|
    # Opt in with `:busybee` on a group or example, so busybee's short names
    # never meet an app's own helpers elsewhere.
    config.include Busybee::Testing::Helpers, :busybee

    # `without_busybee_hooks: [:worker, :call]` on a group or example; innermost wins.
    config.around(:example, :without_busybee_hooks) do |example|
      Busybee::Testing::Helpers::HookScoping.without(*example.metadata[:without_busybee_hooks]) { example.run }
    end
  end
end
