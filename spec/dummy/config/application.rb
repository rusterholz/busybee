# frozen_string_literal: true

require_relative "boot"
require "rails"
require "action_controller/railtie"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.api_only = true
  end
end
