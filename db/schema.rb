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

ActiveRecord::Schema[8.1].define(version: 2026_09_23_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "audit_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.string "actor", null: false
    t.jsonb "changes_made", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "model_version"
    t.datetime "occurred_at", null: false
    t.text "reasoning"
    t.uuid "target_id"
    t.string "target_type"
    t.datetime "updated_at", null: false
    t.index ["actor"], name: "index_audit_events_on_actor"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
    t.index ["target_type", "target_id"], name: "index_audit_events_on_target"
  end

  create_table "companies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "ats_type"
    t.string "careers_page_url"
    t.datetime "created_at", null: false
    t.string "domain"
    t.jsonb "enrichment", default: {}, null: false
    t.string "name", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_companies_on_domain", unique: true, where: "(domain IS NOT NULL)"
    t.index ["enrichment"], name: "index_companies_on_enrichment", using: :gin
    t.index ["name"], name: "index_companies_on_name"
  end

  create_table "postings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "enrichment", default: {}, null: false
    t.datetime "last_checked_at"
    t.string "location"
    t.date "posted_on"
    t.string "posting_url"
    t.string "role_title", null: false
    t.integer "roles_listed_count"
    t.string "source_slice"
    t.datetime "updated_at", null: false
    t.string "verification_state", default: "pending", null: false
    t.string "work_mode"
    t.index ["company_id", "role_title"], name: "index_postings_on_company_id_and_role_title"
    t.index ["company_id"], name: "index_postings_on_company_id"
    t.index ["posting_url"], name: "index_postings_on_posting_url", unique: true, where: "(posting_url IS NOT NULL)"
    t.index ["source_slice"], name: "index_postings_on_source_slice"
    t.index ["verification_state"], name: "index_postings_on_verification_state"
  end

  add_foreign_key "postings", "companies"
end
