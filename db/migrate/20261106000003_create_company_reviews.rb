class CreateCompanyReviews < ActiveRecord::Migration[8.1]
  def change
    # 4b: how well a company fits the operator's company preferences, as their own Claude client researched it: a score
    # from 0 to 100 and why, the facts found with their sources (stage, size, business model, industries and the
    # regions it operates and hires in as values the pages can filter on), one line per preference (match, miss or
    # unknown, with the evidence), concerns and open questions, and the sources checked. Every review is kept; the
    # newest is shown, stale once the preferences it was read against change. Audited by its score, counts and digests,
    # never its text. Goes with its company.
    create_table :company_reviews, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :score, null: false
      t.text :why, null: false
      t.string :stage
      t.string :size
      t.string :business_model
      t.string :industries, array: true, default: [], null: false
      t.string :regions, array: true, default: [], null: false
      t.jsonb :facts, null: false, default: [] # [{ about, said, sources: [url] }]
      t.jsonb :points, null: false, default: [] # [{ about, preference, verdict, evidence, sources: [url] }]
      t.jsonb :concerns, null: false, default: []
      t.jsonb :questions, null: false, default: []
      t.jsonb :sources, null: false, default: []
      t.string :preferences_digest, null: false
      t.string :written_by, null: false
      t.string :reported_model
      t.timestamps
    end
    add_index :company_reviews, %i[company_id created_at]
    add_check_constraint :company_reviews, "score BETWEEN 0 AND 100", name: "company_reviews_score_range"
  end
end
