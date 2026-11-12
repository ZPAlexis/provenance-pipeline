# What a piece of writing read of the operator's background (4c): the version, and the hash of the one part that kind of
# writing may use (background not on the resume for a resume review or a tailored resume; what they're looking for for
# a cover letter or an outreach note), so it says when that part changed since. The lines it drew from the background
# are kept with the points, suggestions or changes that cite them.
class AddBackgroundToWriting < ActiveRecord::Migration[8.1]
  def change
    %i[resume_reviews drafts].each do |table|
      change_table table, bulk: true do |t|
        t.references :background, type: :uuid, foreign_key: { on_delete: :nullify }
        t.string :background_hash
      end
    end
  end
end
