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

ActiveRecord::Schema[8.1].define(version: 2026_10_23_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "activities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.string "kind", null: false
    t.date "occurred_on", null: false
    t.text "summary", null: false
    t.string "logged_by", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "contact_id"
    t.index ["application_id", "occurred_on"], name: "index_activities_on_application_id_and_occurred_on"
    t.index ["application_id"], name: "index_activities_on_application_id"
    t.index ["contact_id"], name: "index_activities_on_contact_id"
  end

  create_table "agent_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "actor", null: false
    t.string "scopes", default: [], null: false, array: true
    t.string "token_digest", null: false
    t.string "purpose", null: false
    t.string "issued_by", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor", "created_at"], name: "index_agent_credentials_on_actor_and_created_at"
    t.index ["token_digest"], name: "index_agent_credentials_on_token_digest", unique: true
  end

  create_table "application_contacts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.uuid "contact_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id", "contact_id"], name: "index_application_contacts_on_application_id_and_contact_id", unique: true
    t.index ["application_id"], name: "index_application_contacts_on_application_id"
    t.index ["contact_id"], name: "index_application_contacts_on_contact_id"
  end

  create_table "applications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "posting_id", null: false
    t.uuid "company_id", null: false
    t.string "stage", null: false
    t.date "stage_changed_on", null: false
    t.string "comp_expectation"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_applications_on_company_id"
    t.index ["posting_id"], name: "index_applications_on_posting_id", unique: true
    t.index ["stage"], name: "index_applications_on_stage"
  end

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
    t.uuid "credential_id"
    t.index ["actor"], name: "index_audit_events_on_actor"
    t.index ["credential_id"], name: "index_audit_events_on_credential_id"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
    t.index ["target_type", "target_id"], name: "index_audit_events_on_target"
  end

  create_table "check_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", null: false
    t.uuid "company_id"
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
    t.integer "total"
    t.jsonb "request", default: {}, null: false
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

  create_table "contacts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "name", null: false
    t.string "role"
    t.string "kind", default: "other", null: false
    t.string "email"
    t.string "linkedin_url"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "name"], name: "index_contacts_on_company_id_and_name"
    t.index ["company_id"], name: "index_contacts_on_company_id"
  end

  create_table "drafts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.string "kind", null: false
    t.string "status", default: "draft", null: false
    t.string "language", null: false
    t.string "asked_language"
    t.text "guidance"
    t.string "subject"
    t.text "body", null: false
    t.string "written_subject"
    t.text "written_body", null: false
    t.jsonb "drew_on", default: [], null: false
    t.jsonb "gaps", default: [], null: false
    t.text "notes"
    t.integer "dropped_lines", default: 0, null: false
    t.uuid "resume_id"
    t.string "resume_hash", null: false
    t.uuid "role_description_id"
    t.string "description_hash", null: false
    t.uuid "llm_call_id"
    t.string "run_id", null: false
    t.datetime "edited_at"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "written_by", default: "agent:drafter", null: false
    t.string "reported_model"
    t.jsonb "tailoring", default: [], null: false
    t.uuid "revises_id"
    t.index ["application_id", "created_at"], name: "index_drafts_on_application_id_and_created_at"
    t.index ["application_id"], name: "index_drafts_on_application_id"
    t.index ["llm_call_id"], name: "index_drafts_on_llm_call_id"
    t.index ["resume_id"], name: "index_drafts_on_resume_id"
    t.index ["revises_id"], name: "index_drafts_on_revises_id"
    t.index ["role_description_id"], name: "index_drafts_on_role_description_id"
  end

  create_table "llm_calls", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "page_check_id"
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
    t.boolean "complete"
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
    t.jsonb "fit"
    t.index ["company_id", "role_title"], name: "index_postings_on_company_id_and_role_title"
    t.index ["company_id"], name: "index_postings_on_company_id"
    t.index ["posting_url"], name: "index_postings_on_posting_url", unique: true, where: "(posting_url IS NOT NULL)"
    t.index ["source_slice"], name: "index_postings_on_source_slice"
    t.index ["tracking"], name: "index_postings_on_tracking"
    t.index ["verification_state"], name: "index_postings_on_verification_state"
  end

  create_table "resume_reviews", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "application_id", null: false
    t.string "language", null: false
    t.jsonb "strengths", default: [], null: false
    t.jsonb "gaps", default: [], null: false
    t.jsonb "suggestions", default: [], null: false
    t.text "note"
    t.integer "dropped_lines", default: 0, null: false
    t.uuid "resume_id"
    t.string "resume_hash", null: false
    t.uuid "role_description_id"
    t.string "description_hash", null: false
    t.string "written_by", null: false
    t.string "reported_model"
    t.uuid "llm_call_id"
    t.string "run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id", "created_at"], name: "index_resume_reviews_on_application_id_and_created_at"
    t.index ["application_id"], name: "index_resume_reviews_on_application_id"
    t.index ["llm_call_id"], name: "index_resume_reviews_on_llm_call_id"
    t.index ["resume_id"], name: "index_resume_reviews_on_resume_id"
    t.index ["role_description_id"], name: "index_resume_reviews_on_role_description_id"
  end

  create_table "resumes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "search_profile_id", null: false
    t.text "text", null: false
    t.string "content_hash", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["search_profile_id", "created_at"], name: "index_resumes_on_search_profile_id_and_created_at"
    t.index ["search_profile_id"], name: "index_resumes_on_search_profile_id"
  end

  create_table "review_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "kind", null: false
    t.uuid "company_id", null: false
    t.string "subject_type", null: false
    t.uuid "subject_id", null: false
    t.string "status", default: "open", null: false
    t.text "evidence", null: false
    t.string "evidence_key", null: false
    t.string "proposal"
    t.string "raised_by", null: false
    t.string "decided_by"
    t.string "decision"
    t.text "note"
    t.datetime "decided_at"
    t.jsonb "recommendation", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_review_items_on_company_id"
    t.index ["kind", "subject_type", "subject_id"], name: "index_review_items_one_open_per_question", unique: true, where: "((status)::text = 'open'::text)"
    t.index ["status"], name: "index_review_items_on_status"
    t.index ["subject_type", "subject_id"], name: "index_review_items_on_subject_type_and_subject_id"
  end

  create_table "role_descriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "posting_id", null: false
    t.text "text", null: false
    t.string "content_hash", null: false
    t.string "read_via", null: false
    t.string "url", null: false
    t.string "run_id", null: false
    t.datetime "first_read_at", null: false
    t.datetime "last_read_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["posting_id", "first_read_at"], name: "index_role_descriptions_on_posting_id_and_first_read_at"
    t.index ["posting_id"], name: "index_role_descriptions_on_posting_id"
  end

  create_table "search_profiles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "titles", default: [], null: false, array: true
    t.string "excluded_words", default: [], null: false, array: true
    t.string "places", default: [], null: false, array: true
    t.string "work_modes", default: [], null: false, array: true
    t.string "levels", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "activities", "applications"
  add_foreign_key "activities", "contacts", on_delete: :nullify
  add_foreign_key "application_contacts", "applications", on_delete: :cascade
  add_foreign_key "application_contacts", "contacts", on_delete: :cascade
  add_foreign_key "applications", "companies"
  add_foreign_key "applications", "postings"
  add_foreign_key "audit_events", "agent_credentials", column: "credential_id"
  add_foreign_key "check_runs", "companies"
  add_foreign_key "check_runs", "postings", on_delete: :nullify
  add_foreign_key "contacts", "companies", on_delete: :cascade
  add_foreign_key "drafts", "applications", on_delete: :cascade
  add_foreign_key "drafts", "drafts", column: "revises_id", on_delete: :nullify
  add_foreign_key "drafts", "llm_calls"
  add_foreign_key "drafts", "resumes", on_delete: :nullify
  add_foreign_key "drafts", "role_descriptions", on_delete: :nullify
  add_foreign_key "llm_calls", "page_checks"
  add_foreign_key "page_checks", "companies"
  add_foreign_key "page_checks", "page_checks", column: "reused_from_id", on_delete: :nullify
  add_foreign_key "postings", "companies"
  add_foreign_key "resume_reviews", "applications", on_delete: :cascade
  add_foreign_key "resume_reviews", "llm_calls"
  add_foreign_key "resume_reviews", "resumes", on_delete: :nullify
  add_foreign_key "resume_reviews", "role_descriptions", on_delete: :nullify
  add_foreign_key "resumes", "search_profiles", on_delete: :cascade
  add_foreign_key "review_items", "companies", on_delete: :cascade
  add_foreign_key "role_descriptions", "postings", on_delete: :cascade
end
