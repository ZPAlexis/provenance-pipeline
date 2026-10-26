class CreateFitScores < ActiveRecord::Migration[8.1]
  def change
    # Stage 2f: how well a role fits the resume, from its own description, for the operator to rank roles by. Every
    # score is kept with the resume and description versions it read; the newest is the one shown, stale once either
    # changes. Its matches keep their resume lines with their text, as a review's do; audited by its score, counts
    # and hashes, never its text. Goes with its role (a withdrawn suggestion takes its scores along).
    create_table :fit_scores, id: :uuid do |t|
      t.references :posting, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :score, null: false
      t.string :level
      t.jsonb :matches, null: false, default: [] # [{ point, lines: [{ line, text }] }]
      t.jsonb :gaps, null: false, default: [] # [{ asks, note }]
      t.text :why, null: false
      t.integer :dropped_lines, null: false, default: 0
      t.references :resume, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :resume_hash, null: false
      t.references :role_description, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :description_hash, null: false
      t.string :written_by, null: false
      t.string :reported_model
      t.references :llm_call, type: :uuid, foreign_key: true
      t.string :run_id
      t.timestamps
    end
    add_index :fit_scores, %i[posting_id created_at]
    add_check_constraint :fit_scores, "score BETWEEN 0 AND 100", name: "fit_scores_score_range"
  end
end
