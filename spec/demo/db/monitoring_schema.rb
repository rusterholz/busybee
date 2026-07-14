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

ActiveRecord::Schema[8.1].define(version: 12) do
  create_table "monitoring_call_metrics", id: :string, force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.float "ewma"
    t.float "ewmv"
    t.float "maximum"
    t.string "metric_name", null: false
    t.float "minimum"
    t.string "tag_key", null: false
    t.json "tags"
    t.index %w[metric_name tag_key], name: "index_monitoring_call_metrics_on_metric_name_and_tag_key", unique: true
    t.index ["metric_name"], name: "index_monitoring_call_metrics_on_metric_name"
  end

  create_table "monitoring_engine_calls", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error_class"
    t.bigint "job_key", null: false
    t.float "network_ms"
    t.string "rpc", null: false
    t.float "seq", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.string "worker_name"
    t.index ["job_key"], name: "index_monitoring_engine_calls_on_job_key"
    t.index ["worker_name"], name: "index_monitoring_engine_calls_on_worker_name"
  end

  create_table "monitoring_job_runs", id: :string, force: :cascade do |t|
    t.datetime "activated_at"
    t.string "bpmn_process_id"
    t.float "buffer_latency_ms"
    t.integer "buffer_size"
    t.boolean "buffered"
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "error_message"
    t.datetime "executed_at"
    t.float "execution_duration_ms"
    t.bigint "job_key", null: false
    t.string "job_type", null: false
    t.integer "lifecycle_rank"
    t.float "perform_duration_ms"
    t.float "seen_at"
    t.string "source"
    t.string "status"
    t.json "tags"
    t.float "total_duration_ms"
    t.datetime "updated_at", null: false
    t.index ["activated_at"], name: "index_monitoring_job_runs_on_activated_at"
    t.index ["job_key"], name: "index_monitoring_job_runs_on_job_key", unique: true
    t.index ["job_type"], name: "index_monitoring_job_runs_on_job_type"
  end

  create_table "monitoring_worker_processes", id: :string, force: :cascade do |t|
    t.integer "backpressure_count"
    t.datetime "created_at", null: false
    t.integer "current_buffer_size"
    t.string "error_class"
    t.string "error_message"
    t.integer "failed_job_count"
    t.string "job_type", null: false
    t.integer "lifecycle_rank"
    t.integer "peak_buffer_size"
    t.string "reason"
    t.float "seen_at"
    t.datetime "shutdown_at"
    t.datetime "started_at"
    t.string "status"
    t.datetime "stop_requested_at"
    t.datetime "stopping_at"
    t.integer "total_job_count"
    t.datetime "updated_at", null: false
    t.string "worker_class"
    t.string "worker_mode"
    t.string "worker_name", null: false
    t.index ["job_type"], name: "index_monitoring_worker_processes_on_job_type"
    t.index ["status"], name: "index_monitoring_worker_processes_on_status"
    t.index %w[worker_name job_type], name: "index_monitoring_worker_processes_on_worker_name_and_job_type",
                                      unique: true
  end
end
