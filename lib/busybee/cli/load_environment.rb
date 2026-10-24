# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require "busybee/logging"

module Busybee
  class CLI
    # Brings the rest of the app up alongside busybee, before the CLI loads its
    # workers, so they reach the app's code and configuration. Rails is the one
    # strategy: it loads unless BUSYBEE_SKIP_RAILS is set or the bundle has no
    # rails, and the CLI carries on where there's no config/environment.rb to
    # load. Any other failure is logged, then raised, for Ruby's own report and
    # exit 1.
    module LoadEnvironment
      RAILS_ENVIRONMENT = "./config/environment"

      class << self
        def call
          return if ENV["BUSYBEE_SKIP_RAILS"].present? || !rails_present?

          require "busybee/railtie" # defensive: busybee.rb's :before_configuration hook registers it already
          require RAILS_ENVIRONMENT
        rescue StandardError, ScriptError => e
          return Logging.info("Continuing without Rails, no config/environment.rb in #{Dir.pwd}") if missing?(e)

          Logging.error("Failed to load Rails environment in #{Dir.pwd}; set BUSYBEE_SKIP_RAILS=1 if this is not a " \
                        "Rails app", error: e)
          raise
        end

        private

        def rails_present?
          require "rails"
          true
        rescue LoadError => e
          missing?(e, "rails") ? false : raise
        end

        def missing?(error, feature = RAILS_ENVIRONMENT) = error.is_a?(LoadError) && error.path == feature
      end
    end
  end
end
