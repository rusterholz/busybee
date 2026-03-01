# frozen_string_literal: true

require "clockwork"
require_relative "config/environment"

module Clockwork
  configure do |config|
    config[:logger] = Rails.logger
  end

  speed = Rails.application.config.x.demo.simulation_speed
  base_interval = Rails.application.config.x.demo.order_interval
  catalog = Rails.application.config.x.demo.item_catalog

  # Clockwork's minimum granularity is 1 second. At high speed factors the
  # scaled interval (base / speed) drops below 1s, so we tick every second and
  # batch-create however many orders are due. A fractional accumulator ensures
  # we don't drift over time.
  tick = [base_interval / speed, 1].max
  orders_per_tick = speed * tick / base_interval
  accumulator = 0.0

  total_created = 0
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  every(tick, "generate_orders") do
    accumulator += orders_per_tick
    batch = accumulator.floor
    accumulator -= batch

    batch.times do
      customer = Faker::Name.name
      items = catalog.sample(rand(3..10))

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

      total_created += 1
      Rails.logger.info("Auto-generated Order ##{order.short_id} for #{customer} (#{items.size} items)")
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    submitted = Oms::Order.where(status: "submitted").count
    Rails.logger.info("[clockwork] tick: #{batch} orders, total: #{total_created}, " \
                      "rate: #{(total_created / elapsed).round(2)}/s, submitted_backlog: #{submitted}")
  end
end
