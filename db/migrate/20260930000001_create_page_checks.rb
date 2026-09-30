class CreatePageChecks < ActiveRecord::Migration[8.1]
  def change
    # Every observation of a company's page: a careers page, a candidate for
    # one, or its homepage. The evidence behind resolution and verification
    # writes, and the check history the audit log deliberately does not hold:
    # a check that changes nothing writes no audit event, but always a row here.
    create_table :page_checks, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid

      # One worker run, e.g. "20260930T101500Z-resolve", so a run's coverage
      # and cost are a single query.
      t.string :run_id, null: false
      t.string :purpose, null: false # resolution | verification
      t.string :step # within resolution: imported | path_probe | homepage | homepage_link | page_link | ats_guess | llm_link

      t.string :url, null: false
      t.string :final_url
      t.string :outcome, null: false # ok | blocked | inaccessible | error
      t.string :reason
      t.string :read_via # how it was read: render+llm | render | ats_api:<vendor> ("method" would shadow Object#method)
      t.string :ats_vendor
      t.string :ats_board
      t.integer :http_status

      # What the page showed. listing_count is the corroborating observable;
      # listings is the snapshot 1.2c matches postings against and 1.4 diffs.
      t.integer :listing_count
      t.integer :stated_total
      t.boolean :explicit_no_openings, null: false, default: false
      t.boolean :listings_incomplete, null: false, default: false # pagination, "load more", or a fuller board elsewhere
      t.boolean :many_employers, null: false, default: false # a job board's or aggregator's listings, not one company's
      t.boolean :input_truncated, null: false, default: false
      t.jsonb :listings, null: false, default: []
      t.text :notes
      t.string :content_hash

      t.datetime :checked_at, null: false
      t.integer :duration_ms

      t.timestamps
    end

    add_index :page_checks, [ :company_id, :checked_at ]
    add_index :page_checks, :run_id
  end
end
