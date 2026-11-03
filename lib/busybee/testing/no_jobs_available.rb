# frozen_string_literal: true

module Busybee
  module Testing
    # Raised when the jobs asked for aren't available for activation
    NoJobsAvailable = Class.new(StandardError)
    NoJobAvailable = NoJobsAvailable
  end
end
