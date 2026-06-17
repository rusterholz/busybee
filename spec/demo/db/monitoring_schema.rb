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

ActiveRecord::Schema[8.1].define(version: 7) do
  create_table "monitoring_job_runs", id: :string, force: :cascade do |t|
    t.datetime "activated_at"
    t.string "bpmn_process_id"
    t.float "buffer_latency_ms"
    t.integer "buffer_size"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "error_message"
    t.datetime "executed_at"
    t.float "execution_duration_ms"
    t.bigint "job_key", null: false
    t.string "job_type", null: false
    t.float "perform_duration_ms"
    t.string "source"
    t.string "status"
    t.json "tags"
    t.float "total_duration_ms"
    t.datetime "updated_at", null: false
    t.index ["activated_at"], name: "index_monitoring_job_runs_on_activated_at"
    t.index ["job_key"], name: "index_monitoring_job_runs_on_job_key", unique: true
    t.index ["job_type"], name: "index_monitoring_job_runs_on_job_type"
  end
end
