# frozen_string_literal: true

# Seed data for the busybee demo app.
#
# Creates 4 warehouses with curated inventory, and 6 drivers.
# Uses a fixed Faker seed for reproducible driver names.

# rubocop:disable Layout/HashAlignment, Style/TrailingCommaInHashLiteral

ITEM_CATALOG = %w[
  wireless-mouse
  usb-c-hub
  laptop-stand
  mechanical-keyboard
  monitor-arm
  webcam
  headset
  desk-lamp
  cable-organizer
  mouse-pad
  usb-drive
  power-strip
  tablet-stylus
  phone-charger
  screen-protector
].freeze

# Warehouse inventory distribution.
# Each warehouse stocks ~10 of 15 items. Key constraints:
# - Every item available at 2+ warehouses
# - 2-3 items available at only 2 warehouses (scarce)
# - Some items at all 4 warehouses (common)
# - Distribution forces multi-warehouse shipments for diverse orders
#
# Legend: number = initial stock quantity, nil = not stocked
WAREHOUSE_INVENTORY = {
  "Warehouse Alpha" => {
    # NW quadrant — stocks many common items
    "wireless-mouse"      => 12,
    "usb-c-hub"           => 8,
    "laptop-stand"        => 10,
    "mechanical-keyboard" => 6,
    "monitor-arm"         => 5,
    "webcam"              => 9,
    "headset"             => 7,
    "desk-lamp"           => 11,
    "cable-organizer"     => 8,
    "mouse-pad"           => 15,
  },
  "Warehouse Beta" => {
    # NE quadrant — overlaps with Alpha, carries some unique items
    "wireless-mouse"      => 10,
    "usb-c-hub"           => 6,
    "laptop-stand"        => 7,
    "mechanical-keyboard" => 9,
    "webcam"              => 5,
    "headset"             => 8,
    "cable-organizer"     => 6,
    "usb-drive"           => 12,
    "power-strip"         => 10,
    "tablet-stylus"       => 7,
  },
  "Warehouse Gamma" => {
    # SW quadrant — broad coverage but lower quantities
    "wireless-mouse"      => 7,
    "usb-c-hub"           => 5,
    "monitor-arm"         => 8,
    "webcam"              => 6,
    "desk-lamp"           => 5,
    "mouse-pad"           => 9,
    "usb-drive"           => 6,
    "power-strip"         => 7,
    "phone-charger"       => 10,
    "screen-protector"    => 8,
  },
  "Warehouse Delta" => {
    # SE quadrant — niche inventory with some exclusive items
    "mechanical-keyboard" => 11,
    "monitor-arm"         => 6,
    "headset"             => 5,
    "desk-lamp"           => 7,
    "mouse-pad"           => 8,
    "power-strip"         => 5,
    "tablet-stylus"       => 9,
    "phone-charger"       => 12,
    "screen-protector"    => 6,
    "cable-organizer"     => 7,
  },
}.freeze

WAREHOUSE_DATA = {
  "Warehouse Alpha" => {
    lat: -6.0, lon: 5.0, address_line_1: "100 Industrial Blvd",
    city: "Northgate", state: "CA", zip: "90001"
  },
  "Warehouse Beta" => {
    lat: 5.0, lon: 7.0, address_line_1: "250 Commerce Dr",
    city: "Eastport", state: "CA", zip: "90002"
  },
  "Warehouse Gamma" => {
    lat: -4.0, lon: -5.0, address_line_1: "75 Logistics Way",
    city: "Southfield", state: "CA", zip: "90003"
  },
  "Warehouse Delta" => {
    lat: 6.0, lon: -3.0, address_line_1: "400 Distribution Ave",
    city: "Westside", state: "CA", zip: "90004"
  },
}.freeze

# rubocop:enable Layout/HashAlignment, Style/TrailingCommaInHashLiteral

puts "Seeding warehouses and inventory..."

WAREHOUSE_DATA.each do |name, data|
  warehouse = Logistics::Warehouse.find_or_create_by!(name: name) do |w|
    w.lat = data[:lat]
    w.lon = data[:lon]
    w.address_line_1 = data[:address_line_1]
    w.city = data[:city]
    w.state = data[:state]
    w.zip = data[:zip]
  end

  WAREHOUSE_INVENTORY[name].each do |item_type, quantity|
    Logistics::StockItem.find_or_create_by!(warehouse: warehouse, item_type: item_type) do |si|
      si.quantity = quantity
    end
  end
end

puts "Seeding drivers..."

Faker::Config.random = Random.new(42) # Fixed seed for reproducible names

6.times do
  name = Faker::Name.name
  Delivery::Driver.find_or_create_by!(name: name) do |d|
    d.total_mileage = 0.0
  end
end

warehouse_count = Logistics::Warehouse.count
stock_count = Logistics::StockItem.count
driver_count = Delivery::Driver.count
puts "Done! #{warehouse_count} warehouses, #{stock_count} stock items, #{driver_count} drivers."
