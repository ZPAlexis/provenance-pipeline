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

ActiveRecord::Schema[8.1].define(version: 2026_10_07_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "audit_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "actor", null: false
    t.string "action", null: false
    t.string "target_type"
    t.uuid "target_id"
    t.jsonb "changes_made", default: {}, null: false
    t.string "model_version"
    t.text "reasoning"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor"], name: "index_audit_events_on_actor"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
    t.index ["target_type", "target_id"], name: "index_audit_events_on_target"
  end

  create_table "check_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", null: false
    t.uuid "company_id", null: false
    t.uuid "posting_id"
    t.string "status", default: "queued", null: false
    t.string "requested_by", null: false
    t.decimal "ceiling_usd", precision: 10, scale: 6
    t.string "answer"
    t.text "summary"
    t.jsonb "tally", default: {}, null: false
    t.decimal "cost_usd", precision: 10, scale: 6
    t.string "run_id"
    t.text "error"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_check_runs_on_company_id"
    t.index ["created_at"], name: "index_check_runs_on_created_at"
    t.index ["posting_id"], name: "index_check_runs_on_posting_id"
    t.index ["status"], name: "index_check_runs_on_status"
  end

  create_table "companies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "domain"
    t.string "careers_page_url"
    t.string "ats_type"
    t.text "notes"
    t.jsonb "enrichment", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "resolution_status"
    t.string "resolution_method"
    t.string "resolution_confidence"
    t.string "resolution_candidate_url"
    t.string "resolution_failure"
    t.datetime "resolved_at"
    t.string "kind"
    t.string "kind_suggestion"
    t.text "kind_evidence"
    t.string "board_vendor"
    t.string "board_token"
    t.decimal "board_overlap", precision: 4, scale: 3
    t.text "board_evidence"
    t.datetime "board_confirmed_at"
    t.index ["domain"], name: "index_companies_on_domain", unique: true, where: "(domain IS NOT NULL)"
    t.index ["enrichment"], name: "index_companies_on_enrichment", using: :gin
    t.index ["name"], name: "index_companies_on_name"
    t.index ["resolution_status"], name: "index_companies_on_resolution_status"
  end

  create_table "llm_calls", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "page_check_id", null: false
    t.string "run_id", null: false
    t.string "purpose", null: false
    t.string "model", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "prompt_version", null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 10, scale: 6, default: "0.0", null: false
    t.datetime "called_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["model", "called_at"], name: "index_llm_calls_on_model_and_called_at"
    t.index ["page_check_id"], name: "index_llm_calls_on_page_check_id"
    t.index ["run_id"], name: "index_llm_calls_on_run_id"
  end

  create_table "page_checks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "run_id", null: false
    t.string "purpose", null: false
    t.string "step"
    t.string "url", null: false
    t.string "final_url"
    t.string "outcome", null: false
    t.string "reason"
    t.string "read_via"
    t.string "ats_vendor"
    t.string "ats_board"
    t.integer "http_status"
    t.integer "listing_count"
    t.integer "stated_total"
    t.boolean "explicit_no_openings", default: false, null: false
    t.boolean "listings_incomplete", default: false, null: false
    t.boolean "many_employers", default: false, null: false
    t.boolean "input_truncated", default: false, null: false
    t.jsonb "listings", default: [], null: false
    t.text "notes"
    t.string "content_hash"
    t.datetime "checked_at", null: false
    t.integer "duration_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "single_job_posting", default: false, null: false
    t.string "next_page_url"
    t.jsonb "matches", default: [], null: false
    t.uuid "reused_from_id"
    t.datetime "listings_read_at"
    t.index ["company_id", "checked_at"], name: "index_page_checks_on_company_id_and_checked_at"
    t.index ["company_id"], name: "index_page_checks_on_company_id"
    t.index ["reused_from_id"], name: "index_page_checks_on_reused_from_id"
    t.index ["run_id"], name: "index_page_checks_on_run_id"
  end

  create_table "postings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "role_title", null: false
    t.string "location"
    t.string "posting_url"
    t.date "posted_on"
    t.string "source_slice"
    t.string "verification_state", default: "pending", null: false
    t.integer "roles_listed_count"
    t.string "work_mode"
    t.datetime "last_checked_at"
    t.jsonb "enrichment", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tracking", default: "tracked", null: false
    t.string "job_url"
    t.index ["company_id", "role_title"], name: "index_postings_on_company_id_and_role_title"
    t.index ["company_id"], name: "index_postings_on_company_id"
    t.index ["posting_url"], name: "index_postings_on_posting_url", unique: true, where: "(posting_url IS NOT NULL)"
    t.index ["source_slice"], name: "index_postings_on_source_slice"
    t.index ["tracking"], name: "index_postings_on_tracking"
    t.index ["verification_state"], name: "index_postings_on_verification_state"
  end

  add_foreign_key "check_runs", "companies"
  add_foreign_key "check_runs", "postings", on_delete: :nullify
  add_foreign_key "llm_calls", "page_checks"
  add_foreign_key "page_checks", "companies"
  add_foreign_key "page_checks", "page_checks", column: "reused_from_id", on_delete: :nullify
  add_foreign_key "postings", "companies"
end
