# frozen_string_literal: true

# Seed data for the busybee demo app.
#
# Creates 4 warehouses with curated inventory, and 4 drivers.
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
# Each warehouse stocks 9 of 15 items. Key constraints:
# - 12 items at exactly 2 warehouses (2 per complementary pair)
# - 3 items at all 4 warehouses (webcam, desk-lamp, mouse-pad)
# - Every pair of warehouses misses exactly 2 items → 3-shipment possible
# - Every triple covers all 15 → 4-shipment impossible
#
# Pair coverage gaps (each pair blocks its complement):
#   {A,B}: phone-charger, screen-protector    — at {G,D}
#   {A,G}: cable-organizer, tablet-stylus     — at {B,D}
#   {A,D}: usb-drive, power-strip             — at {B,G}
#   {B,G}: mechanical-keyboard, headset       — at {A,D}
#   {B,D}: usb-c-hub, monitor-arm             — at {A,G}
#   {G,D}: wireless-mouse, laptop-stand       — at {A,B}
#
# Legend: number = initial stock quantity
WAREHOUSE_INVENTORY = {
  "Warehouse Alpha" => {
    # NW quadrant
    "wireless-mouse"      => 12,
    "laptop-stand"        => 10,
    "usb-c-hub"           => 8,
    "monitor-arm"         => 5,
    "mechanical-keyboard" => 6,
    "headset"             => 7,
    "webcam"              => 9,
    "desk-lamp"           => 11,
    "mouse-pad"           => 15,
  },
  "Warehouse Beta" => {
    # NE quadrant
    "wireless-mouse"      => 10,
    "laptop-stand"        => 7,
    "usb-drive"           => 12,
    "power-strip"         => 10,
    "tablet-stylus"       => 7,
    "cable-organizer"     => 6,
    "webcam"              => 5,
    "desk-lamp"           => 8,
    "mouse-pad"           => 9,
  },
  "Warehouse Gamma" => {
    # SW quadrant
    "usb-c-hub"           => 5,
    "monitor-arm"         => 8,
    "usb-drive"           => 6,
    "power-strip"         => 7,
    "phone-charger"       => 10,
    "screen-protector"    => 8,
    "webcam"              => 6,
    "desk-lamp"           => 5,
    "mouse-pad"           => 9,
  },
  "Warehouse Delta" => {
    # SE quadrant
    "mechanical-keyboard" => 11,
    "headset"             => 5,
    "tablet-stylus"       => 9,
    "cable-organizer"     => 7,
    "phone-charger"       => 12,
    "screen-protector"    => 6,
    "webcam"              => 7,
    "desk-lamp"           => 7,
    "mouse-pad"           => 8,
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

4.times do
  name = Faker::Name.name
  Delivery::Driver.find_or_create_by!(name: name) do |d|
    d.total_mileage = 0.0
  end
end

warehouse_count = Logistics::Warehouse.count
stock_count = Logistics::StockItem.count
driver_count = Delivery::Driver.count
puts "Done! #{warehouse_count} warehouses, #{stock_count} stock items, #{driver_count} drivers."
