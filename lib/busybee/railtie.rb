# frozen_string_literal: true

require "rails"
require "active_support/core_ext/object/blank"
require "busybee"

module Busybee
  # Rails integration for Busybee.
  # Automatically configures Busybee from Rails configuration.
  #
  # @example config/application.rb or config/environments/*.rb
  #   config.x.busybee.cluster_address = "cluster.zeebe.camunda.io:443"
  #   config.x.busybee.client_id = ENV["CAMUNDA_CLIENT_ID"]
  #   config.x.busybee.client_secret = ENV["CAMUNDA_CLIENT_SECRET"]
  #   config.x.busybee.cluster_id = ENV["CAMUNDA_CLUSTER_ID"]
  #
  class Railtie < Rails::Railtie
    initializer "busybee.configure" do
      Busybee.configure do |config|
        busybee_conf = Rails.configuration.x.busybee.presence

        # Use Rails logger by default in Rails apps
        config.logger = Rails.logger
        config.cluster_address = busybee_conf&.cluster_address.presence
      end
    end
  end
end
