# Screen risk (4d): each must-have the role states, read one by one, shown on the resume, shown only in the background,
# or not shown (null for a score weighed before the check). A must-have not shown on the resume caps the ATS fit at 69,
# one shown nowhere caps the Background fit; the score as weighed is kept beside the capped one, set only when capped.
class AddMustHavesToFitScores < ActiveRecord::Migration[8.1]
  def change
    change_table :fit_scores, bulk: true do |t|
      t.jsonb :must_haves
      t.integer :score_before_cap
      t.integer :background_score_before_cap
    end
    add_check_constraint :fit_scores, "score_before_cap IS NULL OR score_before_cap BETWEEN 70 AND 100",
                         name: "fit_scores_score_before_cap_range"
    add_check_constraint :fit_scores, "background_score_before_cap IS NULL OR background_score_before_cap BETWEEN 70 AND 100",
                         name: "fit_scores_background_score_before_cap_range"
  end
end
