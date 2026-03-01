# frozen_string_literal: true

namespace :demo do
  desc "Create N orders and verify they all reach fulfilled status"
  task :run_orders, [:count] => :environment do |_t, args|
    count = (args[:count] || 10).to_i
    speed = Rails.application.config.x.demo.simulation_speed
    catalog = Rails.application.config.x.demo.item_catalog

    puts "Creating #{count} orders at speed #{speed}..."

    order_ids = count.times.map do |i|
      order = ActiveRecord::Base.transaction do
        Oms::Order.create!(
          customer_name: "Test Customer #{i + 1}",
          address_line_1: "#{100 + i} Test St",
          city: "Testville",
          state: "TS",
          zip: "00000",
          lat: rand(-90..90) / 10.0,
          lon: rand(-90..90) / 10.0
        ).tap do |o|
          catalog.sample(rand(3..10)).each do |item_type|
            Oms::LineItem.create!(order: o, item_type: item_type, quantity: 1)
          end
        end
      end
      print "."
      order.id
    end
    puts " created #{order_ids.size} orders"

    # Poll until all orders reach fulfilled status
    timeout = [count * 120.0 / speed, 30].max
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    poll_interval = [2.0 / speed, 0.5].max

    puts "Waiting up to #{timeout.round}s for all orders to reach 'fulfilled'..."

    loop do
      remaining = Oms::Order.where(id: order_ids).where.not(status: "fulfilled").count
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - (deadline - timeout)

      if remaining == 0
        puts "All #{count} orders fulfilled in #{elapsed.round(1)}s"
        break
      end

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        statuses = Oms::Order.where(id: order_ids).group(:status).count
        $stderr.puts "\nTIMEOUT after #{timeout.round}s — #{remaining} orders not fulfilled"
        $stderr.puts "Order statuses: #{statuses.inspect}"

        # Diagnostic: show stuck orders
        Oms::Order.where(id: order_ids).where.not(status: "fulfilled").limit(5).each do |order|
          shipments = Logistics::Shipment.where(order_id: order.id)
          $stderr.puts "  Order #{order.short_id} (#{order.status}): " \
                       "#{shipments.count} shipments — #{shipments.group(:status).count.inspect}"
        end

        exit 1
      end

      sleep(poll_interval)
    end

    # Verify final state
    errors = []

    # All shipments delivered
    undelivered = Logistics::Shipment.where(order_id: order_ids).where.not(status: "delivered").count
    errors << "#{undelivered} shipments not delivered" if undelivered > 0

    # All drivers released
    busy_drivers = Delivery::Driver.where.not(current_shipment_id: nil).count
    errors << "#{busy_drivers} drivers still assigned" if busy_drivers > 0

    if errors.any?
      $stderr.puts "\nVerification failed:"
      errors.each { |e| $stderr.puts "  - #{e}" }
      exit 1
    end

    total_shipments = Logistics::Shipment.where(order_id: order_ids).count
    total_drivers = Delivery::Driver.count
    puts "Verified: #{total_shipments} shipments delivered, #{total_drivers} drivers idle"
    puts "PASS"
  end
end
