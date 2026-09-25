class CreatePostings < ActiveRecord::Migration[8.1]
  def change
    create_table :postings, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid

      t.string :role_title, null: false
      t.string :location
      t.string :posting_url
      t.date :posted_on

      # Which sourcing pull this posting came from (brazil / canada / us / global).
      # Lives here rather than on companies: one company can surface in several
      # geographic pulls, so the slice describes the posting, not the company.
      t.string :source_slice

      # --- Verification state, written by the verifier agent (Stage 1.2) ---
      t.string :verification_state, null: false, default: "pending"

      # Corroborating observable: total roles visible on the careers page,
      # regardless of whether the target role matched. Distinguishes a credible
      # negative (not_found + 23 roles listed) from a likely parse failure
      # (not_found + 0 roles listed).
      t.integer :roles_listed_count

      t.string :work_mode
      t.datetime :last_checked_at

      t.jsonb :enrichment, null: false, default: {}

      t.timestamps
    end

    # Posting URL is the dedup key for re-imports.
    add_index :postings, :posting_url, unique: true, where: "posting_url IS NOT NULL"
    add_index :postings, :verification_state
    add_index :postings, :source_slice
    add_index :postings, [ :company_id, :role_title ]
  end
end
