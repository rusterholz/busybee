# frozen_string_literal: true

require "rails"
require "busybee"

module Busybee
  # Rails integration for Busybee.
  # Automatically configures Busybee from Rails configuration.
  #
  # @example config/application.rb or config/environments/*.rb
  #   config.x.busybee.address = "cluster.zeebe.camunda.io:443"
  #   config.x.busybee.client_id = ENV["CAMUNDA_CLIENT_ID"]
  #   config.x.busybee.client_secret = ENV["CAMUNDA_CLIENT_SECRET"]
  #   config.x.busybee.cluster_id = ENV["CAMUNDA_CLUSTER_ID"]
  #
  class Railtie < Rails::Railtie
    initializer "busybee.configure" do
      # Configuration wiring will be added as we implement config attributes
    end
  end
end
