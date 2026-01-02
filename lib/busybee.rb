# frozen_string_literal: true

require_relative "busybee/version"
require_relative "busybee/defaults"

# Top-level gem module, only holds configuration values.
module Busybee
  class << self
    attr_writer :cluster_address
    attr_accessor :logger

    def configure
      yield self
    end

    def cluster_address
      @cluster_address || ENV.fetch("CLUSTER_ADDRESS", "localhost:26500")
    end
  end
end

require_relative "busybee/railtie" if defined?(Rails::Railtie)
