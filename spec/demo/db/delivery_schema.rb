# frozen_string_literal: true

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 5) do
  create_table "delivery_driver_requests", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "driver_id"
    t.datetime "requested_at", null: false
    t.string "shipment_id", null: false
    t.datetime "updated_at", null: false
    t.index %w[driver_id requested_at], name: "index_delivery_driver_requests_open", where: "driver_id IS NULL"
    t.index ["driver_id"], name: "index_delivery_driver_requests_on_driver_id"
  end

  create_table "delivery_drivers", id: :string, force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "current_shipment_id"
    t.string "name", null: false
    t.decimal "total_mileage", precision: 8, scale: 2, default: "0.0", null: false
  end
end
