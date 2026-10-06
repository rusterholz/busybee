# frozen_string_literal: true

module Busybee
  module Testing
    # Raised when no job is available for activation
    NoJobAvailable = Class.new(StandardError)
  end
end
