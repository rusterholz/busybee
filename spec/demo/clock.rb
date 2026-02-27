# frozen_string_literal: true

require "clockwork"
require_relative "config/environment"

module Clockwork
  configure do |config|
    config[:logger] = Rails.logger
  end

  interval = Rails.application.config.x.demo.order_interval
  catalog = Rails.application.config.x.demo.item_catalog

  every(interval, "generate_order") do
    customer = Faker::Name.name
    item_count = rand(3..10)
    items = catalog.sample(item_count)

    order = ActiveRecord::Base.transaction do
      Oms::Order.create!(
        customer_name: customer,
        address_line_1: Faker::Address.street_address,
        city: Faker::Address.city,
        state: Faker::Address.state_abbr,
        zip: Faker::Address.zip_code,
        lat: rand(-90..90) / 10.0,
        lon: rand(-90..90) / 10.0
      ).tap do |o|
        items.each do |item_type|
          Oms::LineItem.create!(order: o, item_type: item_type, quantity: 1)
        end
      end
    end

    Rails.logger.info("Auto-generated Order ##{order.short_id} for #{customer} (#{item_count} item types)")
  end
end
