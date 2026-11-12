# A role's fit read two ways (4c): `score` stays the ATS fit, the resume alone as a recruiter's system reads it; beside
# it, the Background fit, read with the operator's background too: its score and why, the gaps of the ATS reading the
# background covers (each with the background lines and where to address it), how the role sits with the role
# preferences, and the background version it read, so it goes stale on its own when the background changes.
class AddBackgroundFitToFitScores < ActiveRecord::Migration[8.1]
  def change
    change_table :fit_scores, bulk: true do |t|
      t.integer :background_score
      t.text :background_why
      t.jsonb :covered, default: [], null: false
      t.jsonb :preferences, default: [], null: false
      t.integer :background_dropped_lines, default: 0, null: false
      t.references :background, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :background_hash
    end
    add_check_constraint :fit_scores, "background_score IS NULL OR background_score BETWEEN 0 AND 100", name: "fit_scores_background_score_range"
  end
end
