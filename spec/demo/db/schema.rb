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

ActiveRecord::Schema[8.1].define(version: 3) do
  create_table "delivery_drivers", id: :string, force: :cascade do |t|
    t.string "current_shipment_id"
    t.string "name", null: false
    t.decimal "total_mileage", precision: 8, scale: 2, default: "0.0", null: false
  end

  create_table "logistics_shipments", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "deliver_shipment_instance_key"
    t.json "items"
    t.string "order_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "warehouse_id", null: false
    t.index ["order_id"], name: "index_logistics_shipments_on_order_id"
    t.index ["warehouse_id"], name: "index_logistics_shipments_on_warehouse_id"
  end

  create_table "logistics_stock_items", id: :string, force: :cascade do |t|
    t.string "item_type", null: false
    t.integer "quantity", default: 0, null: false
    t.string "warehouse_id", null: false
    t.index ["warehouse_id", "item_type"], name: "index_logistics_stock_items_on_warehouse_id_and_item_type", unique: true
    t.index ["warehouse_id"], name: "index_logistics_stock_items_on_warehouse_id"
  end

  create_table "logistics_warehouses", id: :string, force: :cascade do |t|
    t.string "address_line_1"
    t.string "city"
    t.decimal "lat", precision: 5, scale: 1, null: false
    t.decimal "lon", precision: 5, scale: 1, null: false
    t.string "name", null: false
    t.string "state"
    t.string "zip"
  end

  create_table "oms_line_items", id: :string, force: :cascade do |t|
    t.string "item_type", null: false
    t.string "order_id", null: false
    t.integer "quantity", default: 1, null: false
    t.index ["order_id"], name: "index_oms_line_items_on_order_id"
  end

  create_table "oms_orders", id: :string, force: :cascade do |t|
    t.string "address_line_1"
    t.string "city"
    t.datetime "created_at", null: false
    t.string "customer_name", null: false
    t.decimal "lat", precision: 5, scale: 1, null: false
    t.decimal "lon", precision: 5, scale: 1, null: false
    t.bigint "prepare_order_instance_key"
    t.bigint "ship_order_instance_key"
    t.string "state"
    t.string "status", default: "submitted", null: false
    t.datetime "updated_at", null: false
    t.string "zip"
  end
end
