# frozen_string_literal: true

require_relative "busybee/version"

# Top-level gem module, only holds configuration values.
module Busybee
end

require_relative "busybee/railtie" if defined?(Rails::Railtie)
